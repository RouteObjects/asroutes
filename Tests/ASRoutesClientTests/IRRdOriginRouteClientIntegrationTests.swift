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

import ASRoutesClient
import CIDR
import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import ASRoutesCLI

@Suite("IRRd origin-route client loopback integration")
struct IRRdOriginRouteClientIntegrationTests {
    @Test("pipelines direct-AS queries and associates framed responses FIFO")
    func pipelinesQueriesAndAssociatesResponsesFIFO() async throws {
        let server = try await FakeIRRdServer.start(behavior: .explicitSourcesAndThreeRoutes)

        do {
            let configuration = IRRdClientConfiguration(
                host: "127.0.0.1",
                port: server.port,
                sources: ["TEST", "ALT"],
                connectTimeout: .seconds(2),
                queryTimeout: .seconds(2)
            )
            let client = IRRdOriginRouteClient(configuration: configuration)

            let results: [ASOriginIPv4Routes] = try await client.ipv4Routes(for: [
                AutonomousSystemNumber(701),
                AutonomousSystemNumber(64_500),
                AutonomousSystemNumber(64_496),
            ])

            try #require(results.count == 3)
            #expect(
                results.map(\.asn) == [
                    AutonomousSystemNumber(701),
                    AutonomousSystemNumber(64_500),
                    AutonomousSystemNumber(64_496),
                ])
            #expect(
                results[0].prefixes.map(\.description) == [
                    "10.0.0.0/8",
                    "203.0.113.0/24",
                ])
            #expect(results[1].prefixes.isEmpty)
            // Keep both the covering route and its more-specific while removing the exact duplicate.
            #expect(
                results[2].prefixes.map(\.description) == [
                    "192.0.2.0/24",
                    "192.0.2.128/25",
                ])
            #expect(await server.connectionClosed.wait(timeout: .seconds(1)))
            #expect(
                server.commands.snapshot() == [
                    "!!",
                    "!n asroutes",
                    "!s-lc",
                    "!sTEST,ALT",
                    "!gAS701",
                    "!gAS64500",
                    "!gAS64496",
                    "!q",
                ])

            try await server.shutdown()
        } catch {
            await server.shutdownAfterFailure()
            throw error
        }
    }

    @Test("pipelines IPv6 direct-AS queries and associates framed responses FIFO")
    func pipelinesIPv6QueriesAndAssociatesResponsesFIFO() async throws {
        let server = try await FakeIRRdServer.start(behavior: .explicitSourcesAndThreeIPv6Routes)

        do {
            let configuration = IRRdClientConfiguration(
                host: "127.0.0.1",
                port: server.port,
                sources: ["TEST", "ALT"],
                connectTimeout: .seconds(2),
                queryTimeout: .seconds(2)
            )
            let client = IRRdOriginRouteClient(configuration: configuration)

            let results: [ASOriginIPv6Routes] = try await client.ipv6Routes(for: [
                AutonomousSystemNumber(701),
                AutonomousSystemNumber(64_500),
                AutonomousSystemNumber(64_496),
            ])

            try #require(results.count == 3)
            #expect(
                results.map(\.asn) == [
                    AutonomousSystemNumber(701),
                    AutonomousSystemNumber(64_500),
                    AutonomousSystemNumber(64_496),
                ])
            #expect(
                results[0].prefixes.map(\.description) == [
                    "2001:db8::/32",
                    "2001:db8:1::/48",
                ])
            #expect(results[1].prefixes.isEmpty)
            // Keep the covering IPv6 route and its more-specific while removing the exact duplicate.
            #expect(
                results[2].prefixes.map(\.description) == [
                    "2001:db8:2::/48",
                    "2001:db8:2:8000::/49",
                ])
            #expect(await server.connectionClosed.wait(timeout: .seconds(1)))
            #expect(
                server.commands.snapshot() == [
                    "!!",
                    "!n asroutes",
                    "!s-lc",
                    "!sTEST,ALT",
                    "!6AS701",
                    "!6AS64500",
                    "!6AS64496",
                    "!q",
                ])

            try await server.shutdown()
        } catch {
            await server.shutdownAfterFailure()
            throw error
        }
    }

    @Test("reasserts the server's discovered source order when no sources are configured")
    func reassertsDiscoveredSources() async throws {
        let server = try await FakeIRRdServer.start(behavior: .discoveredSourcesAndSingleRoute)

        do {
            let client = IRRdOriginRouteClient(
                configuration: IRRdClientConfiguration(
                    host: "127.0.0.1",
                    port: server.port,
                    sources: nil,
                    connectTimeout: .seconds(2),
                    queryTimeout: .seconds(2)
                )
            )

            let results = try await client.ipv4Routes(for: [AutonomousSystemNumber(701)])

            try #require(results.count == 1)
            #expect(results[0].prefixes.map(\.description) == ["198.51.100.0/24"])
            #expect(await server.connectionClosed.wait(timeout: .seconds(1)))
            #expect(
                server.commands.snapshot() == [
                    "!!",
                    "!n asroutes",
                    "!s-lc",
                    "!sDEFAULT,ALT",
                    "!gAS701",
                    "!q",
                ])

            try await server.shutdown()
        } catch {
            await server.shutdownAfterFailure()
            throw error
        }
    }

    @Test("a session accepts cumulative successful payloads exactly at its ceiling")
    func sessionResponseCeilingAcceptsExactTotal() async throws {
        let server = try await FakeIRRdServer.start(behavior: .twoSuccessfulRoutes)
        let sourcePayload = "DEFAULT,ALT"
        let firstRoutePayload = "10.0.0.0/8"
        let secondRoutePayload = "192.0.2.0/24"
        let exactBytes =
            sourcePayload.utf8.count + 1
            + firstRoutePayload.utf8.count + 1
            + secondRoutePayload.utf8.count + 1

        do {
            let client = IRRdOriginRouteClient(
                configuration: IRRdClientConfiguration(
                    host: "127.0.0.1",
                    port: server.port,
                    connectTimeout: .seconds(2),
                    queryTimeout: .seconds(2),
                    maximumSessionResponseBytes: exactBytes
                )
            )

            let results = try await client.ipv4Routes(for: [
                AutonomousSystemNumber(701),
                AutonomousSystemNumber(64_500),
            ])

            #expect(
                results.map(\.prefixes).map { $0.map(\.description) } == [
                    [firstRoutePayload],
                    [secondRoutePayload],
                ])
            #expect(await server.connectionClosed.wait(timeout: .seconds(1)))
            #expect(server.commands.snapshot().last == "!q")

            try await server.shutdown()
        } catch {
            await server.shutdownAfterFailure()
            throw error
        }
    }

    @Test("the session ceiling counts every successful payload and preserves atomic output")
    func sessionResponseCeilingRejectsCumulativePayloads() async throws {
        let server = try await FakeIRRdServer.start(behavior: .twoSuccessfulRoutes)
        let output = RecordedOutput()
        let sourcePayload = "DEFAULT,ALT"
        let firstRoutePayload = "10.0.0.0/8"
        let secondRoutePayload = "192.0.2.0/24"
        // Set the ceiling to exactly the two route payloads; rejection therefore proves
        // that the preceding successful source-discovery payload participates in the same budget.
        let routeOnlyBytes =
            firstRoutePayload.utf8.count + 1
            + secondRoutePayload.utf8.count + 1
        let accumulatedBytes = sourcePayload.utf8.count + 1 + routeOnlyBytes

        do {
            let configuration = IRRdClientConfiguration(
                host: "127.0.0.1",
                port: server.port,
                connectTimeout: .seconds(2),
                queryTimeout: .seconds(2),
                maximumSessionResponseBytes: routeOnlyBytes
            )
            let application = ASRoutesApplication(
                routeLookup: { configuration, asns in
                    try await IRRdOriginRouteClient(configuration: configuration).ipv4Routes(
                        for: asns
                    )
                },
                outputWriter: { output.write($0) }
            )

            do {
                try await application.run(
                    configuration: configuration,
                    asns: [
                        AutonomousSystemNumber(701),
                        AutonomousSystemNumber(64_500),
                    ]
                )
                Issue.record("Expected cumulative responses to exceed the session ceiling")
            } catch let error as IRRdOriginRouteClientError {
                #expect(
                    error
                        == .sessionResponseTooLarge(
                            limit: routeOnlyBytes,
                            accumulated: accumulatedBytes
                        )
                )
            } catch {
                Issue.record("Expected sessionResponseTooLarge, received \(error)")
            }

            #expect(output.snapshot().isEmpty)
            #expect(await server.connectionClosed.wait(timeout: .seconds(1)))
            #expect(
                server.commands.snapshot() == [
                    "!!",
                    "!n asroutes",
                    "!s-lc",
                    "!sDEFAULT,ALT",
                    "!gAS701",
                    "!gAS64500",
                ]
            )

            try await server.shutdown()
        } catch {
            await server.shutdownAfterFailure()
            throw error
        }
    }

    @Test("partial-frame byte drips cannot evade the response deadline")
    func queryTimeoutClosesSlowDripConnection() async throws {
        let server = try await FakeIRRdServer.start(behavior: .slowDripRoute)

        do {
            let client = IRRdOriginRouteClient(
                configuration: IRRdClientConfiguration(
                    host: "127.0.0.1",
                    port: server.port,
                    connectTimeout: .seconds(2),
                    // Leave enough wall-clock margin for a contended shared runner. The
                    // 1,000-byte, 40 ms drip still needs roughly 40 seconds to complete its frame.
                    queryTimeout: .seconds(2)
                )
            )

            do {
                _ = try await client.ipv4Routes(for: [AutonomousSystemNumber(701)])
                Issue.record("Expected the stalled route query to time out")
            } catch let error as IRRdOriginRouteClientError {
                #expect(error == .timeout(operation: "response"))
            } catch {
                Issue.record("Expected a typed query timeout, received \(error)")
            }

            #expect(await server.connectionClosed.wait(timeout: .seconds(1)))
            #expect(
                server.commands.snapshot() == [
                    "!!",
                    "!n asroutes",
                    "!s-lc",
                    "!sDEFAULT,ALT",
                    "!gAS701",
                ])

            try await server.shutdown()
        } catch {
            await server.shutdownAfterFailure()
            throw error
        }
    }

    @Test("task cancellation closes an in-flight query connection")
    func cancellationClosesConnection() async throws {
        let server = try await FakeIRRdServer.start(behavior: .stalledRoute)

        do {
            let client = IRRdOriginRouteClient(
                configuration: IRRdClientConfiguration(
                    host: "127.0.0.1",
                    port: server.port,
                    connectTimeout: .seconds(2),
                    queryTimeout: .seconds(2)
                )
            )
            let query = Task {
                try await client.ipv4Routes(for: [AutonomousSystemNumber(701)])
            }

            try #require(await server.routeReceived.wait(timeout: .seconds(1)))
            query.cancel()

            do {
                _ = try await query.value
                Issue.record("Expected cancellation to end the in-flight query")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Expected CancellationError, received \(error)")
            }

            #expect(await server.connectionClosed.wait(timeout: .seconds(1)))
            #expect(
                server.commands.snapshot() == [
                    "!!",
                    "!n asroutes",
                    "!s-lc",
                    "!sDEFAULT,ALT",
                    "!gAS701",
                ])

            try await server.shutdown()
        } catch {
            await server.shutdownAfterFailure()
            throw error
        }
    }

    @Test("a later server failure does not return an earlier ASN's partial result")
    func laterFailureDoesNotReturnPartialResults() async throws {
        let server = try await FakeIRRdServer.start(behavior: .partialResultThenFailure)
        let output = RecordedOutput()

        do {
            let configuration = IRRdClientConfiguration(
                host: "127.0.0.1",
                port: server.port,
                connectTimeout: .seconds(2),
                queryTimeout: .seconds(2)
            )
            let application = ASRoutesApplication(
                routeLookup: { configuration, asns in
                    try await IRRdOriginRouteClient(configuration: configuration).ipv4Routes(
                        for: asns
                    )
                },
                outputWriter: { renderedOutput in
                    output.write(renderedOutput)
                }
            )

            do {
                try await application.run(
                    configuration: configuration,
                    asns: [
                        AutonomousSystemNumber(701),
                        AutonomousSystemNumber(64_500),
                    ]
                )
                Issue.record("Expected the second response to fail the whole request")
            } catch let error as IRRdOriginRouteClientError {
                #expect(error == .serverFailure("synthetic second-query failure"))
            } catch {
                Issue.record("Expected a typed server failure, received \(error)")
            }

            #expect(output.snapshot().isEmpty)
            #expect(await server.connectionClosed.wait(timeout: .seconds(1)))
            #expect(
                server.commands.snapshot() == [
                    "!!",
                    "!n asroutes",
                    "!s-lc",
                    "!sDEFAULT,ALT",
                    "!gAS701",
                    "!gAS64500",
                ])

            try await server.shutdown()
        } catch {
            await server.shutdownAfterFailure()
            throw error
        }
    }
}

private struct FakeIRRdServer {
    let group: MultiThreadedEventLoopGroup
    let listener: Channel
    let port: Int
    let commands: RecordedCommands
    let routeReceived: EventSignal
    let connectionClosed: EventSignal

    static func start(behavior: FakeIRRdServerBehavior) async throws -> FakeIRRdServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let commands = RecordedCommands()
        let routeReceived = EventSignal()
        let connectionClosed = EventSignal()

        do {
            let listener = try await ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                // TCP_NODELAY must use IPPROTO_TCP; SOL_SOCKET maps its numeric value
                // to privileged SO_DEBUG on Linux and rejects the accepted channel with EPERM.
                .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            FakeIRRdServerHandler(
                                behavior: behavior,
                                commands: commands,
                                routeReceived: routeReceived,
                                connectionClosed: connectionClosed
                            )
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()

            guard let port = listener.localAddress?.port else {
                try await listener.close().get()
                try await group.shutdownGracefully()
                throw FakeIRRdServerError.missingBoundPort
            }

            return FakeIRRdServer(
                group: group,
                listener: listener,
                port: port,
                commands: commands,
                routeReceived: routeReceived,
                connectionClosed: connectionClosed
            )
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func shutdown() async throws {
        try await listener.close().get()
        try await group.shutdownGracefully()
    }

    func shutdownAfterFailure() async {
        try? await listener.close().get()
        try? await group.shutdownGracefully()
    }
}

private enum FakeIRRdServerError: Error {
    case missingBoundPort
}

private enum FakeIRRdServerBehavior: Sendable {
    case explicitSourcesAndThreeRoutes
    case explicitSourcesAndThreeIPv6Routes
    case discoveredSourcesAndSingleRoute
    case twoSuccessfulRoutes
    case stalledRoute
    case slowDripRoute
    case partialResultThenFailure
}

private final class EventSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func signal() {
        continuation.yield(())
        continuation.finish()
    }

    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = self.stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

private final class RecordedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ command: String) {
        lock.lock()
        storage.append(command)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class RecordedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func write(_ output: String) {
        lock.lock()
        storage.append(output)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// The handler is confined to one NIO event loop; unchecked Sendable documents that confinement.
private final class FakeIRRdServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let behavior: FakeIRRdServerBehavior
    private let commands: RecordedCommands
    private let routeReceived: EventSignal
    private let connectionClosed: EventSignal
    private var inbound = ByteBufferAllocator().buffer(capacity: 256)
    private var receivedRouteCommands: [String] = []
    private var dripContext: ChannelHandlerContext?

    init(
        behavior: FakeIRRdServerBehavior,
        commands: RecordedCommands,
        routeReceived: EventSignal,
        connectionClosed: EventSignal
    ) {
        self.behavior = behavior
        self.commands = commands
        self.routeReceived = routeReceived
        self.connectionClosed = connectionClosed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        inbound.writeBuffer(&incoming)

        while let newlineIndex = inbound.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) {
            let byteCount = newlineIndex - inbound.readerIndex
            guard var command = inbound.readString(length: byteCount) else {
                context.close(promise: nil)
                return
            }
            inbound.moveReaderIndex(forwardBy: 1)
            if command.last == "\r" {
                command.removeLast()
            }
            handle(command: command, context: context)
        }

        inbound.discardReadBytes()
    }

    func channelInactive(context: ChannelHandlerContext) {
        dripContext = nil
        connectionClosed.signal()
        context.fireChannelInactive()
    }

    private func handle(command: String, context: ChannelHandlerContext) {
        commands.append(command)

        switch command {
        case "!!":
            // IRRd's multi-command marker deliberately has no response.
            break
        case "!n asroutes":
            write("C\n", context: context)
        case "!s-lc":
            write(Self.dataResponse("DEFAULT,ALT"), context: context)
        case let sourceCommand where sourceCommand.hasPrefix("!s"):
            write("C\n", context: context)
        // Both compact direct-origin commands share framing and FIFO semantics;
        // accepting either family keeps the loopback harness focused on protocol behavior.
        case let routeCommand
        where routeCommand.hasPrefix("!gAS") || routeCommand.hasPrefix("!6AS"):
            routeReceived.signal()
            receivedRouteCommands.append(routeCommand)
            respondToRouteQueriesIfReady(context: context)
        case "!q":
            context.close(promise: nil)
        default:
            write("F unexpected command: \(command)\n", context: context)
            context.close(promise: nil)
        }
    }

    private func respondToRouteQueriesIfReady(context: ChannelHandlerContext) {
        switch behavior {
        case .explicitSourcesAndThreeRoutes:
            guard receivedRouteCommands.count == 3 else { return }

            // Withhold all route replies until every request arrives, proving the client pipelines them.
            let combinedResponses =
                Self.dataResponse("203.0.113.0/24 10.0.0.0/8")
                + "D\n"
                + Self.dataResponse("192.0.2.128/25 192.0.2.0/24 192.0.2.128/25")
            write(combinedResponses, context: context)
        case .explicitSourcesAndThreeIPv6Routes:
            guard receivedRouteCommands.count == 3 else { return }

            // Expanded and uppercase input verifies canonical IPv6 rendering in addition
            // to pipelining, FIFO association, an empty middle result, and exact deduplication.
            let combinedResponses =
                Self.dataResponse(
                    "2001:0DB8:0001:0000:0000:0000:0000:0000/48 2001:0DB8:0000:0000:0000:0000:0000:0000/32"
                )
                + "D\n"
                + Self.dataResponse(
                    "2001:db8:2:8000::/49 2001:db8:2::/48 2001:db8:2:8000::/49"
                )
            write(combinedResponses, context: context)
        case .discoveredSourcesAndSingleRoute:
            guard receivedRouteCommands.count == 1 else { return }
            write(Self.dataResponse("198.51.100.0/24"), context: context)
        case .twoSuccessfulRoutes:
            guard receivedRouteCommands.count == 2 else { return }
            write(
                Self.dataResponse("10.0.0.0/8")
                    + Self.dataResponse("192.0.2.0/24"),
                context: context
            )
        case .stalledRoute:
            break
        case .slowDripRoute:
            guard receivedRouteCommands.count == 1 else { return }
            // Raw bytes arrive more frequently than the configured timeout,
            // but never form a complete response before its absolute frame deadline.
            write("A1000\n", context: context)
            dripContext = context
            scheduleNextDrip(on: context.eventLoop)
        case .partialResultThenFailure:
            guard receivedRouteCommands.count == 2 else { return }
            let combinedResponses =
                Self.dataResponse("10.0.0.0/8")
                + "F synthetic second-query failure\n"
            write(combinedResponses, context: context)
        }
    }

    private func write(_ response: String, context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: response.utf8.count)
        buffer.writeString(response)
        context.writeAndFlush(NIOAny(buffer), promise: nil)
    }

    private func scheduleNextDrip(on eventLoop: any EventLoop) {
        eventLoop.scheduleTask(in: .milliseconds(40)) {
            self.writeNextDrip()
        }
    }

    private func writeNextDrip() {
        guard let context = dripContext, context.channel.isActive else {
            dripContext = nil
            return
        }

        write("x", context: context)
        scheduleNextDrip(on: context.eventLoop)
    }

    private static func dataResponse(_ content: String) -> String {
        let payload = content + "\n"
        return "A\(payload.utf8.count)\n\(payload)C\n"
    }
}
