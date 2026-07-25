//===----------------------------------------------------------------------===//
//
// This source file is part of the asroutes project.
//
// Copyright (c) 2026 Craig A. Munro
//
// Licensed under the Apache License, Version 2.0.
// See the LICENSE file for details.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

/// Bridges an async operation that may not observe task cancellation promptly.
func awaitPromptlyCancellableValue<Value: Sendable>(
    operation: @escaping @Sendable () async throws -> Value,
    onCancel: @escaping @Sendable () -> Void = {},
    cleanup: @escaping @Sendable (Value) async -> Void
) async throws -> Value {
    let handoff = PromptCancellationHandoff<Value>(onCancel: onCancel)

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard handoff.install(continuation) else { return }

            // SwiftNIO's EventLoopFuture.get() may ignore task cancellation. The
            // producer may therefore outlive its caller, while this explicit handoff decides
            // exactly once whether a value transfers or requires late cleanup.
            let producer = Task {
                do {
                    let value = try await operation()
                    if handoff.succeed(value) {
                        // A fresh unstructured task does not inherit the producer's
                        // cancelled state, so cancellation-aware cleanup cannot be abandoned.
                        let cleanupTask = Task {
                            await cleanup(value)
                        }
                        await cleanupTask.value
                    }
                } catch {
                    handoff.fail(error)
                }
            }
            handoff.attach(producer)
        }
    } onCancel: {
        handoff.cancel()
    }
}

// A lock-backed state machine closes the cancellation-registration race without
// actor hops. Continuations and Task cancellation are both safe to trigger from any thread.
final class PromptCancellationHandoff<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case awaitingWaiter
        case waiting(CheckedContinuation<Value, any Error>)
        case cancelling(CheckedContinuation<Value, any Error>?)
        case cancelled
        case completed
    }

    private let lock = NSLock()
    private let onCancel: @Sendable () -> Void
    private var state = State.awaitingWaiter
    private var producer: Task<Void, Never>?

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        let shouldStartProducer: Bool
        let shouldResumeCancellation: Bool

        lock.lock()
        switch state {
        case .awaitingWaiter:
            state = .waiting(continuation)
            shouldStartProducer = true
            shouldResumeCancellation = false
        case .cancelling(nil):
            state = .cancelling(continuation)
            shouldStartProducer = false
            shouldResumeCancellation = false
        case .cancelled:
            shouldStartProducer = false
            shouldResumeCancellation = true
        case .waiting, .cancelling(.some), .completed:
            lock.unlock()
            preconditionFailure("A prompt-cancellation continuation was installed more than once")
        }
        lock.unlock()

        if shouldResumeCancellation {
            continuation.resume(throwing: CancellationError())
        }
        return shouldStartProducer
    }

    func attach(_ producer: Task<Void, Never>) {
        let shouldCancel: Bool

        lock.lock()
        switch state {
        case .waiting:
            self.producer = producer
            shouldCancel = false
        case .cancelling, .cancelled, .completed:
            shouldCancel = true
        case .awaitingWaiter:
            lock.unlock()
            preconditionFailure("A producer was attached before its waiter")
        }
        lock.unlock()

        if shouldCancel {
            producer.cancel()
        }
    }

    /// Returns `true` when cancellation already won and the caller must clean up `value`.
    func succeed(_ value: Value) -> Bool {
        let continuation: CheckedContinuation<Value, any Error>

        lock.lock()
        switch state {
        case .waiting(let waiter):
            state = .completed
            producer = nil
            continuation = waiter
            lock.unlock()
            continuation.resume(returning: value)
            return false
        case .cancelling, .cancelled:
            producer = nil
            lock.unlock()
            return true
        case .awaitingWaiter, .completed:
            lock.unlock()
            preconditionFailure("A prompt-cancellation producer completed more than once")
        }
    }

    func fail(_ error: any Error) {
        let continuation: CheckedContinuation<Value, any Error>?

        lock.lock()
        switch state {
        case .waiting(let waiter):
            state = .completed
            producer = nil
            continuation = waiter
        case .cancelling, .cancelled:
            producer = nil
            continuation = nil
        case .awaitingWaiter, .completed:
            lock.unlock()
            preconditionFailure("A prompt-cancellation producer completed more than once")
        }
        lock.unlock()

        continuation?.resume(throwing: error)
    }

    func cancel() {
        let producer: Task<Void, Never>?
        let shouldCancel: Bool

        lock.lock()
        switch state {
        case .awaitingWaiter:
            state = .cancelling(nil)
            producer = self.producer
            self.producer = nil
            shouldCancel = true
        case .waiting(let waiter):
            state = .cancelling(waiter)
            producer = self.producer
            self.producer = nil
            shouldCancel = true
        case .cancelling, .cancelled, .completed:
            producer = nil
            shouldCancel = false
        }
        lock.unlock()

        guard shouldCancel else { return }

        producer?.cancel()
        onCancel()
        finishCancellation()
    }

    private func finishCancellation() {
        let continuation: CheckedContinuation<Value, any Error>?

        lock.lock()
        switch state {
        case .cancelling(let waiter):
            state = .cancelled
            continuation = waiter
        case .awaitingWaiter, .waiting, .cancelled, .completed:
            lock.unlock()
            preconditionFailure("A prompt cancellation was finalized from an invalid state")
        }
        lock.unlock()

        continuation?.resume(throwing: CancellationError())
    }
}
