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
import NIOEmbedded
import Testing

@testable import ASRoutes

@Suite("prompt cancellation bridge")
struct PromptCancellationTests {
    @Test("cancellation returns before an unaware operation and cleans its late value")
    func cancellationCleansUpLateValue() async throws {
        let gate = UncancellableGate<Int>()
        let completion = TestSignal<OperationCompletion>()
        let cleanup = TestSignal<Int>()
        let cancellationHook = TestSignal<Void>()

        let operation = Task {
            try await awaitPromptlyCancellableValue {
                await gate.value()
            } onCancel: {
                cancellationHook.send(())
            } cleanup: { value in
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

        // CHANGE: The caller must finish while the simulated bootstrap remains suspended.
        #expect(await completion.wait(timeout: .milliseconds(250)) == .cancelled)
        #expect(await cancellationHook.wait(timeout: .milliseconds(250)) != nil)

        gate.resume(returning: 42)
        #expect(await cleanup.wait(timeout: .seconds(1)) == 42)
        _ = await observer.result
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

private enum OperationCompletion: Sendable, Equatable {
    case returnedValue
    case cancelled
    case otherError
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
