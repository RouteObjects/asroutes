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

import CIDR
import Foundation
import NIOCore
import NIOPosix

/// A SwiftNIO client for retrieving IRR route-object prefixes by origin AS.
public struct IRRdOriginRouteClient: Sendable {
    /// The connection, source-selection, timeout, and response-size settings.
    public let configuration: IRRdClientConfiguration

    /// Creates an origin-route client.
    ///
    /// - Parameter configuration: The settings used for each lookup session.
    public init(configuration: IRRdClientConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Retrieves IPv4 origin-route prefixes for each distinct autonomous system.
    ///
    /// Results preserve first-seen ASN order, exact-deduplicate prefixes, retain covered
    /// more-specifics, and become available only after the complete session succeeds.
    /// Cancellation closes the active channel and is rethrown as `CancellationError`.
    ///
    /// - Parameter asns: The autonomous systems to query; duplicate values are queried once.
    /// - Returns: One result per distinct ASN, including results with no visible prefixes.
    /// - Throws: `CancellationError`, or an ``IRRdOriginRouteClientError`` for configuration,
    ///   transport, timeout, size-limit, protocol, server, or prefix failures.
    public func ipv4Routes(for asns: [AutonomousSystemNumber]) async throws -> [ASOriginIPv4Routes] {
        try await originRoutes(
            for: asns,
            queryPrefix: "!gAS",
            parsePrefixes: { try Self.parseIPv4Prefixes($0) },
            makeResult: { ASOriginIPv4Routes(asn: $0, prefixes: $1) }
        )
    }

    /// Retrieves IPv6 origin-route prefixes for each distinct autonomous system.
    ///
    /// Results preserve first-seen ASN order, exact-deduplicate prefixes, retain covered
    /// more-specifics, and become available only after the complete session succeeds.
    /// Cancellation closes the active channel and is rethrown as `CancellationError`.
    ///
    /// - Parameter asns: The autonomous systems to query; duplicate values are queried once.
    /// - Returns: One result per distinct ASN, including results with no visible prefixes.
    /// - Throws: `CancellationError`, or an ``IRRdOriginRouteClientError`` for configuration,
    ///   transport, timeout, size-limit, protocol, server, or prefix failures.
    public func ipv6Routes(for asns: [AutonomousSystemNumber]) async throws -> [ASOriginIPv6Routes] {
        try await originRoutes(
            for: asns,
            queryPrefix: "!6AS",
            parsePrefixes: { try Self.parseIPv6Prefixes($0) },
            makeResult: { ASOriginIPv6Routes(asn: $0, prefixes: $1) }
        )
    }

    private func originRoutes<Prefix: Sendable, Result: Sendable>(
        for asns: [AutonomousSystemNumber],
        queryPrefix: String,
        parsePrefixes: @escaping @Sendable (String) throws -> [Prefix],
        makeResult: @escaping @Sendable (AutonomousSystemNumber, [Prefix]) -> Result
    ) async throws -> [Result] {
        let validated = try ValidatedConfiguration(configuration)
        let uniqueASNs = Self.uniqued(asns)
        guard !uniqueASNs.isEmpty else { return [] }

        let connection: IRRdConnection
        do {
            connection = try await Self.connect(using: validated)
        } catch ChannelError.connectTimeout {
            throw IRRdOriginRouteClientError.timeout(operation: "connection")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as IRRdOriginRouteClientError {
            throw error
        } catch {
            throw IRRdOriginRouteClientError.transportFailure(String(describing: error))
        }

        do {
            return try await connection.channel.executeThenClose { inbound, outbound in
                try Task.checkCancellation()
                var responses = inbound.makeAsyncIterator()

                // `!!` intentionally has no response.
                try await outbound.write(ByteBuffer(string: "!!\n"))

                try await connection.responseDeadline.expectResponses(1)
                try await outbound.write(ByteBuffer(string: "!n asroutes\n"))
                try Self.requireEmptyControlResponse(
                    try await Self.nextResponse(from: &responses),
                    command: "!n"
                )

                try await connection.responseDeadline.expectResponses(1)
                try await outbound.write(ByteBuffer(string: "!s-lc\n"))
                let serverSources = try Self.parseSources(
                    from: try await Self.nextResponse(from: &responses)
                )
                let selectedSources = validated.sources ?? serverSources

                try await connection.responseDeadline.expectResponses(1)
                try await outbound.write(
                    ByteBuffer(string: "!s\(selectedSources.joined(separator: ","))\n")
                )
                try Self.requireEmptyControlResponse(
                    try await Self.nextResponse(from: &responses),
                    command: "!s"
                )

                // CHANGE: Both origin-query families use the same FIFO session workflow; only the
                // command prefix and typed payload parser vary, preventing protocol behavior drift.
                try await connection.responseDeadline.expectResponses(uniqueASNs.count)
                // CHANGE: Submit the pipelined route commands as one writer sequence so the
                // response deadline cannot advance while the task is suspended between writes.
                let routeCommands = uniqueASNs.map { asn in
                    ByteBuffer(string: "\(queryPrefix)\(asn.description)\n")
                }
                try await outbound.write(contentsOf: routeCommands)

                var results: [Result] = []
                results.reserveCapacity(uniqueASNs.count)

                for asn in uniqueASNs {
                    let response = try await Self.nextResponse(from: &responses)
                    let prefixes: [Prefix]

                    switch response {
                    case .success(let payload, _):
                        prefixes = try parsePrefixes(payload)
                    case .empty, .notFound:
                        prefixes = []
                    }

                    results.append(makeResult(asn, prefixes))
                }

                try await outbound.write(ByteBuffer(string: "!q\n"))
                return results
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as IRRdOriginRouteClientError {
            throw error
        } catch {
            throw IRRdOriginRouteClientError.transportFailure(String(describing: error))
        }
    }
}

private struct IRRdConnection: Sendable {
    let channel: NIOAsyncChannel<IRRdResponse, ByteBuffer>
    let responseDeadline: IRRdResponseDeadlineHandler
}

extension IRRdOriginRouteClient {
    fileprivate static func connect(using configuration: ValidatedConfiguration) async throws
        -> IRRdConnection
    {
        let pendingChannels = PendingChannelRegistry()
        defer { pendingChannels.releaseAll() }

        return try await awaitPromptlyCancellableValue {
            try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectTimeout(configuration.connectTimeout)
                .connect(host: configuration.host, port: configuration.port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        guard pendingChannels.register(channel) else {
                            throw CancellationError()
                        }

                        let responseDeadline = IRRdResponseDeadlineHandler(
                            eventLoop: channel.eventLoop,
                            timeout: configuration.queryTimeout
                        )

                        // CHANGE: Install framing and complete-response deadlines before the
                        // async wrapper so no IRRd bytes can bypass protocol enforcement.
                        try channel.pipeline.syncOperations.addHandler(
                            ByteToMessageHandler(
                                IRRdFrameDecoder(
                                    maximumResponseBytes: configuration.maximumResponseBytes,
                                    maximumSessionResponseBytes: configuration.maximumSessionResponseBytes
                                )
                            )
                        )
                        try channel.pipeline.syncOperations.addHandler(responseDeadline)

                        return IRRdConnection(
                            channel: try NIOAsyncChannel<IRRdResponse, ByteBuffer>(
                                wrappingChannelSynchronously: channel
                            ),
                            responseDeadline: responseDeadline
                        )
                    }
                }
        } onCancel: {
            // Closing a raw channel interrupts a pending socket connect instead of waiting
            // for the bootstrap's cancellation-unaware future to reach its timeout.
            pendingChannels.cancelAndClose()
        } cleanup: { lateConnection in
            // DNS may still finish after cancellation created no raw channel. If that race
            // produces a connection, close it before it can become an orphaned session.
            _ = try? await lateConnection.channel.executeThenClose { _, _ in () }
        }
    }
}

extension IRRdOriginRouteClient {
    static func parseIPv4Prefixes(_ payload: String) throws -> [IPv4Network] {
        try parsePrefixes(payload, as: IPv4Network.self)
    }

    static func parseIPv6Prefixes(_ payload: String) throws -> [IPv6Network] {
        try parsePrefixes(payload, as: IPv6Network.self)
    }

    private static func parsePrefixes<Family: IPAddressFamily>(
        _ payload: String,
        as _: IPNetwork<Family>.Type
    ) throws -> [IPNetwork<Family>] {
        var prefixes = Set<IPNetwork<Family>>()

        for token in payload.split(whereSeparator: { $0.isWhitespace }) {
            let text = String(token)
            guard let prefix = IPNetwork<Family>(text) else {
                throw IRRdOriginRouteClientError.invalidPrefix(text)
            }
            prefixes.insert(prefix)
        }

        // CHANGE: Compare address storage rather than rendered text so IPv4 and IPv6 both have
        // stable numeric network ordering, with less-specific prefixes first at one boundary.
        return prefixes.sorted { lhs, rhs in
            if lhs.prefix != rhs.prefix {
                return lhs.prefix < rhs.prefix
            }
            return lhs.prefixLength < rhs.prefixLength
        }
    }

    private static func uniqued(
        _ asns: [AutonomousSystemNumber]
    ) -> [AutonomousSystemNumber] {
        var seen = Set<AutonomousSystemNumber>()
        return asns.filter { seen.insert($0).inserted }
    }

    private static func nextResponse(
        from iterator: inout NIOAsyncChannelInboundStream<IRRdResponse>.AsyncIterator
    ) async throws -> IRRdResponse {
        guard let response = try await iterator.next() else {
            throw IRRdOriginRouteClientError.protocolViolation(
                "connection closed before the expected response"
            )
        }
        return response
    }

    private static func requireEmptyControlResponse(_ response: IRRdResponse, command: String) throws {
        guard case .empty = response else {
            throw IRRdOriginRouteClientError.protocolViolation(
                "\(command) returned data instead of an empty success response"
            )
        }
    }

    private static func parseSources(from response: IRRdResponse) throws -> [String] {
        guard case .success(let payload, _) = response else {
            throw IRRdOriginRouteClientError.protocolViolation(
                "!s-lc did not return a source list"
            )
        }

        return try IRRdSourceList.parseDiscovered(payload)
    }
}

private struct ValidatedConfiguration: Sendable {
    let host: String
    let port: Int
    let sources: [String]?
    let connectTimeout: TimeAmount
    let queryTimeout: TimeAmount
    let maximumResponseBytes: Int
    let maximumSessionResponseBytes: Int

    init(_ configuration: IRRdClientConfiguration) throws {
        let host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw IRRdOriginRouteClientError.invalidConfiguration("host must not be empty")
        }
        guard (1...65_535).contains(configuration.port) else {
            throw IRRdOriginRouteClientError.invalidConfiguration("port must be between 1 and 65535")
        }
        guard let connectTimeout = configuration.connectTimeout.nioTimeAmount else {
            throw IRRdOriginRouteClientError.invalidConfiguration("connect timeout must be positive")
        }
        guard let queryTimeout = configuration.queryTimeout.nioTimeAmount else {
            throw IRRdOriginRouteClientError.invalidConfiguration("query timeout must be positive")
        }
        guard configuration.maximumResponseBytes > 0 else {
            throw IRRdOriginRouteClientError.invalidConfiguration(
                "maximum response size must be positive"
            )
        }
        guard configuration.maximumSessionResponseBytes > 0 else {
            throw IRRdOriginRouteClientError.invalidConfiguration(
                "maximum session response size must be positive"
            )
        }

        self.host = host
        self.port = configuration.port
        self.sources = try IRRdSourceList.normalizeConfigured(configuration.sources)
        self.connectTimeout = connectTimeout
        self.queryTimeout = queryTimeout
        self.maximumResponseBytes = configuration.maximumResponseBytes
        self.maximumSessionResponseBytes = configuration.maximumSessionResponseBytes
    }
}
