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

import Dispatch
import Foundation
import NIOEmbedded
import Testing

@testable import ASRoutesClient

@Suite("prompt cancellation bridge")
struct PromptCancellationTests {
    @Test("a successful value transfers without invoking cancellation or cleanup")
    func successfulValueTransfersExactlyOnce() async throws {
        let recorder = HandoffRecorder()

        // Repetition exercises the producer/consumer scheduling boundary that exposed
        // premature channel closure on Linux after a successful connection handoff.
        for value in 0..<256 {
            let result = try await awaitPromptlyCancellableValue {
                value
            } onCancel: {
                recorder.recordCancellation()
            } cleanup: { cleanedValue in
                recorder.recordCleanup(cleanedValue, wasCancelled: Task.isCancelled)
            }

            #expect(result == value)
        }

        #expect(
            recorder.snapshot()
                == .init(
                    cancellations: 0,
                    cleanedValues: [],
                    cleanupCancellationStates: []
                )
        )
    }

    @Test("cancellation returns before an unaware operation and cleans its late value")
    func cancellationCleansUpLateValue() async throws {
        let gate = UncancellableGate<Int>()
        let completion = TestSignal<OperationCompletion>()
        let cleanup = TestSignal<Int>()
        let cancellationHook = TestSignal<Void>()
        let recorder = HandoffRecorder()

        let operation = Task {
            try await awaitPromptlyCancellableValue {
                await gate.value()
            } onCancel: {
                recorder.recordCancellation()
                cancellationHook.send(())
            } cleanup: { value in
                recorder.recordCleanup(value, wasCancelled: Task.isCancelled)
                cleanup.send(value)
            }
        }

        try #require(await gate.started.wait(timeout: .seconds(1)) != nil)

        let observer = Task {
            do {
                _ = try await operation.value
                completion.send(.returnedValue)
            } catch is CancellationError {
                completion.send(.cancelled)
            } catch {
                completion.send(.otherError)
            }
        }

        operation.cancel()
        operation.cancel()
        operation.cancel()

        // The caller must finish while the simulated bootstrap remains suspended.
        #expect(await completion.wait(timeout: .milliseconds(250)) == .cancelled)
        #expect(await cancellationHook.wait(timeout: .milliseconds(250)) != nil)

        gate.resume(returning: 42)
        #expect(await cleanup.wait(timeout: .seconds(1)) == 42)
        _ = await observer.result
        #expect(
            recorder.snapshot()
                == .init(
                    cancellations: 1,
                    cleanedValues: [42],
                    cleanupCancellationStates: [false]
                )
        )
    }

    @Test("cancellation waits for its synchronous hook before resuming the caller")
    func cancellationWaitsForHook() async throws {
        let gate = UncancellableGate<Int>()
        let hook = BlockingCancellationHook()
        defer { hook.release() }
        let completion = OperationCompletionRecorder()
        let cleanup = TestSignal<Int>()
        let cancellationFinished = TestSignal<Void>()

        let operation = Task {
            try await awaitPromptlyCancellableValue {
                await gate.value()
            } onCancel: {
                hook.call()
            } cleanup: { value in
                cleanup.send(value)
            }
        }

        try #require(await gate.started.wait(timeout: .seconds(1)) != nil)

        let observer = Task {
            do {
                _ = try await operation.value
                completion.record(.returnedValue)
            } catch is CancellationError {
                completion.record(.cancelled)
            } catch {
                completion.record(.otherError)
            }
        }
        // The hook deliberately blocks, so cancel from a GCD worker rather than
        // consuming a cooperative-executor thread while the ordering is asserted.
        DispatchQueue.global().async {
            operation.cancel()
            cancellationFinished.send(())
        }

        try #require(await hook.started.wait(timeout: .seconds(1)) != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(completion.snapshot() == nil)

        hook.release()
        #expect(await cancellationFinished.wait(timeout: .seconds(1)) != nil)
        #expect(await completion.wait(timeout: .seconds(1)) == .cancelled)

        gate.resume(returning: 7)
        #expect(await cleanup.wait(timeout: .seconds(1)) == 7)
        _ = await observer.result
    }

    @Test("waiter registration during cancellation waits for the hook")
    func waiterRegistrationDuringCancellationWaitsForHook() async throws {
        let hook = BlockingCancellationHook()
        defer { hook.release() }
        let completion = OperationCompletionRecorder()
        let cancellationFinished = TestSignal<Void>()
        let handoff = PromptCancellationHandoff<Int> {
            hook.call()
        }

        DispatchQueue.global().async {
            handoff.cancel()
            cancellationFinished.send(())
        }
        try #require(await hook.started.wait(timeout: .seconds(1)) != nil)

        let waiter = Task {
            do {
                let _: Int = try await withCheckedThrowingContinuation { continuation in
                    #expect(!handoff.install(continuation))
                }
                completion.record(.returnedValue)
            } catch is CancellationError {
                completion.record(.cancelled)
            } catch {
                completion.record(.otherError)
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        #expect(completion.snapshot() == nil)

        hook.release()
        #expect(await cancellationFinished.wait(timeout: .seconds(1)) != nil)
        #expect(await completion.wait(timeout: .seconds(1)) == .cancelled)
        _ = await waiter.result
    }

    @Test("immediate cancellation completes and invokes its hook exactly once")
    func immediateCancellationCompletesExactlyOnce() async throws {
        for _ in 0..<64 {
            let recorder = HandoffRecorder()
            let operation = Task {
                try await awaitPromptlyCancellableValue {
                    try await Task.sleep(for: .seconds(10))
                    return 1
                } onCancel: {
                    recorder.recordCancellation()
                } cleanup: { value in
                    recorder.recordCleanup(value, wasCancelled: Task.isCancelled)
                }
            }

            operation.cancel()
            operation.cancel()

            do {
                _ = try await operation.value
                Issue.record("Expected immediate cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Expected CancellationError, received \(error)")
            }

            #expect(
                recorder.snapshot()
                    == .init(
                        cancellations: 1,
                        cleanedValues: [],
                        cleanupCancellationStates: []
                    )
            )
        }
    }

    @Test("operation errors do not invoke cancellation or cleanup")
    func operationErrorDoesNotCancel() async {
        let recorder = HandoffRecorder()

        do {
            let _: Int = try await awaitPromptlyCancellableValue {
                throw SyntheticOperationError.expected
            } onCancel: {
                recorder.recordCancellation()
            } cleanup: { value in
                recorder.recordCleanup(value, wasCancelled: Task.isCancelled)
            }
            Issue.record("Expected the operation error")
        } catch let error as SyntheticOperationError {
            #expect(error == .expected)
        } catch {
            Issue.record("Expected SyntheticOperationError, received \(error)")
        }

        #expect(
            recorder.snapshot()
                == .init(
                    cancellations: 0,
                    cleanedValues: [],
                    cleanupCancellationStates: []
                )
        )
    }

    @Test("an operation-originated CancellationError does not invoke the hook")
    func operationCancellationErrorDoesNotCancelCaller() async {
        let recorder = HandoffRecorder()

        do {
            let _: Int = try await awaitPromptlyCancellableValue {
                throw CancellationError()
            } onCancel: {
                recorder.recordCancellation()
            } cleanup: { value in
                recorder.recordCleanup(value, wasCancelled: Task.isCancelled)
            }
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected from the operation, not from caller cancellation.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }

        #expect(
            recorder.snapshot()
                == .init(
                    cancellations: 0,
                    cleanedValues: [],
                    cleanupCancellationStates: []
                )
        )
    }

    @Test("cancelling a pending-channel registry closes current and late channels")
    func pendingChannelRegistryClosesChannels() {
        let registry = PendingChannelRegistry()
        let currentChannel = EmbeddedChannel()

        #expect(registry.register(currentChannel))
        registry.cancelAndClose()
        currentChannel.embeddedEventLoop.run()
        #expect(!currentChannel.isActive)
        _ = try? currentChannel.finish()

        let lateChannel = EmbeddedChannel()
        #expect(!registry.register(lateChannel))
        lateChannel.embeddedEventLoop.run()
        #expect(!lateChannel.isActive)
        _ = try? lateChannel.finish()
    }
}

private struct HandoffRecord: Equatable {
    let cancellations: Int
    let cleanedValues: [Int]
    let cleanupCancellationStates: [Bool]
}

private final class HandoffRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0
    private var cleanedValues: [Int] = []
    private var cleanupCancellationStates: [Bool] = []

    func recordCancellation() {
        lock.lock()
        cancellations += 1
        lock.unlock()
    }

    func recordCleanup(_ value: Int, wasCancelled: Bool) {
        lock.lock()
        cleanedValues.append(value)
        cleanupCancellationStates.append(wasCancelled)
        lock.unlock()
    }

    func snapshot() -> HandoffRecord {
        lock.lock()
        defer { lock.unlock() }
        return HandoffRecord(
            cancellations: cancellations,
            cleanedValues: cleanedValues,
            cleanupCancellationStates: cleanupCancellationStates
        )
    }
}

private enum SyntheticOperationError: Error, Equatable {
    case expected
}

private enum OperationCompletion: Sendable, Equatable {
    case returnedValue
    case cancelled
    case otherError
}

private final class OperationCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OperationCompletion?

    func record(_ value: OperationCompletion) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func snapshot() -> OperationCompletion? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func wait(timeout: Duration) async -> OperationCompletion? {
        await withTaskGroup(of: OperationCompletion?.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    if let value = self.snapshot() {
                        return value
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

private final class UncancellableGate<Value: Sendable>: @unchecked Sendable {
    let started = TestSignal<Void>()

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            started.send(())
        }
    }

    func resume(returning value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

private final class BlockingCancellationHook: @unchecked Sendable {
    let started = TestSignal<Void>()

    private let condition = NSCondition()
    private var isReleased = false

    func call() {
        started.send(())
        condition.lock()
        while !isReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class TestSignal<Element: Sendable>: Sendable {
    private let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func send(_ element: Element) {
        continuation.yield(element)
        continuation.finish()
    }

    func wait(timeout: Duration) async -> Element? {
        await withTaskGroup(of: Element?.self) { group in
            group.addTask {
                var iterator = self.stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
