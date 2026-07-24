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
    let (stream, continuation) = AsyncThrowingStream<Value, any Error>.makeStream(
        bufferingPolicy: .bufferingOldest(1)
    )

    // CHANGE: SwiftNIO's EventLoopFuture.get() does not cancel the underlying DNS/
    // connect future. This producer may briefly outlive its caller, but it owns and
    // cleans up any value that arrives after the stream has been cancelled.
    let producer = Task {
        do {
            let value = try await operation()

            guard !Task.isCancelled else {
                await cleanup(value)
                continuation.finish()
                return
            }

            switch continuation.yield(value) {
            case .enqueued:
                continuation.finish()
            case .dropped(let droppedValue):
                await cleanup(droppedValue)
                continuation.finish()
            case .terminated:
                await cleanup(value)
            @unknown default:
                await cleanup(value)
                continuation.finish()
            }
        } catch {
            continuation.finish(throwing: error)
        }
    }

    continuation.onTermination = { @Sendable termination in
        if case .cancelled = termination {
            onCancel()
            producer.cancel()
        }
    }

    var iterator = stream.makeAsyncIterator()
    do {
        guard let value = try await iterator.next() else {
            onCancel()
            producer.cancel()
            throw CancellationError()
        }

        guard !Task.isCancelled else {
            onCancel()
            producer.cancel()
            await cleanup(value)
            throw CancellationError()
        }
        return value
    } catch is CancellationError {
        onCancel()
        producer.cancel()
        throw CancellationError()
    }
}
