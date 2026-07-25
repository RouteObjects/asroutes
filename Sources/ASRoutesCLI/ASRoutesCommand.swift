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
import ArgumentParser
import CIDR
import Foundation

// Package access lets the thin executable invoke Argument Parser directly while this
// command remains in the regular ASRoutesCLI module used by tests.
package struct ASRoutesCommand: AsyncParsableCommand {
    static let version = "0.1.0"

    package static let configuration = CommandConfiguration(
        commandName: "asroutes",
        abstract: "List IPv4 or IPv6 IRR route-object prefixes for origin AS numbers.",
        discussion: """
            Queries an IRRd raw-Whois service over plaintext TCP port 43. Results reflect the \
            server's selected IRR sources; they are not observed live-BGP routes.
            """,
        version: version
    )

    @Flag
    var addressFamily: RouteFamilyOption = .ipv4

    @Option(name: .long, help: "IRRd host to query.")
    var host = "rr.ntt.net"

    @Option(name: .long, help: "IRRd raw-Whois TCP port.")
    var port = 43

    @Option(
        name: .long,
        help: "Comma-separated IRR sources. By default, use the server-selected sources."
    )
    var sources: String?

    @Option(name: .long, help: "Connection timeout in seconds.")
    var connectTimeout = 10.0

    @Option(name: .long, help: "Timeout for each IRRd response in seconds.")
    var queryTimeout = 30.0

    @Argument(help: "One or more AS numbers, written as 701 or AS701.")
    var asnOperands: [String] = []

    package init() {}

    package mutating func run() async throws {
        let asns = try ASNOperandParser.parse(asnOperands)
        let clientConfiguration = try CLIConfigurationBuilder.make(
            host: host,
            port: port,
            sources: sources,
            connectTimeoutSeconds: connectTimeout,
            queryTimeoutSeconds: queryTimeout
        )

        try await ASRoutesApplication.live.run(
            configuration: clientConfiguration,
            asns: asns,
            addressFamily: addressFamily
        )
    }
}

enum RouteFamilyOption: Sendable, EnumerableFlag {
    case ipv4
    case ipv6

    static func name(for value: Self) -> NameSpecification {
        switch value {
        case .ipv4:
            return .customShort("4")
        case .ipv6:
            return .customShort("6")
        }
    }

    static func help(for value: Self) -> ArgumentHelp? {
        switch value {
        case .ipv4:
            return "Retrieve IPv4 route-object prefixes (default)."
        case .ipv6:
            return "Retrieve IPv6 route-object prefixes."
        }
    }
}

struct ASRoutesApplication: Sendable {
    typealias IPv4RouteLookup =
        @Sendable (
            _ configuration: IRRdClientConfiguration,
            _ asns: [AutonomousSystemNumber]
        ) async throws -> [ASOriginIPv4Routes]
    typealias IPv6RouteLookup =
        @Sendable (
            _ configuration: IRRdClientConfiguration,
            _ asns: [AutonomousSystemNumber]
        ) async throws -> [ASOriginIPv6Routes]
    typealias RouteLookup = IPv4RouteLookup
    typealias OutputWriter = @Sendable (_ output: String) -> Void

    static let live = ASRoutesApplication(
        routeLookup: { configuration, asns in
            try await IRRdOriginRouteClient(configuration: configuration).ipv4Routes(for: asns)
        },
        ipv6RouteLookup: { configuration, asns in
            try await IRRdOriginRouteClient(configuration: configuration).ipv6Routes(for: asns)
        },
        outputWriter: { print($0) }
    )

    let ipv4RouteLookup: IPv4RouteLookup
    let ipv6RouteLookup: IPv6RouteLookup
    let outputWriter: OutputWriter

    init(
        routeLookup: @escaping IPv4RouteLookup,
        ipv6RouteLookup: @escaping IPv6RouteLookup = { configuration, asns in
            try await IRRdOriginRouteClient(configuration: configuration).ipv6Routes(for: asns)
        },
        outputWriter: @escaping OutputWriter
    ) {
        self.ipv4RouteLookup = routeLookup
        self.ipv6RouteLookup = ipv6RouteLookup
        self.outputWriter = outputWriter
    }

    func run(
        configuration: IRRdClientConfiguration,
        asns: [AutonomousSystemNumber]
    ) async throws {
        try await run(configuration: configuration, asns: asns, addressFamily: .ipv4)
    }

    func run(
        configuration: IRRdClientConfiguration,
        asns: [AutonomousSystemNumber],
        addressFamily: RouteFamilyOption
    ) async throws {
        let renderedOutput: String
        // Keep IPv4 and IPv6 lookups strongly typed while sharing the CLI's atomic
        // dispatch and output boundary.
        switch addressFamily {
        case .ipv4:
            renderedOutput = GroupedRouteRenderer.render(
                try await ipv4RouteLookup(configuration, asns)
            )
        case .ipv6:
            renderedOutput = GroupedRouteRenderer.render(
                try await ipv6RouteLookup(configuration, asns)
            )
        }

        // The output sink is invoked only after every query and prefix parse succeeds,
        // making an all-AS snapshot atomic even when a later response fails.
        outputWriter(renderedOutput)
    }
}

enum ASNOperandParser {
    static func parse(_ operands: [String]) throws -> [AutonomousSystemNumber] {
        guard !operands.isEmpty else {
            throw ValidationError("At least one ASN is required.")
        }

        var seen: Set<AutonomousSystemNumber> = []
        var result: [AutonomousSystemNumber] = []
        result.reserveCapacity(operands.count)

        for operand in operands {
            guard let asn = parseCanonicalOperand(operand) else {
                throw ValidationError(
                    "Invalid ASN '\(operand)'. Expected canonical asplain or an uppercase AS-prefixed form, such as 701 or AS701."
                )
            }

            if seen.insert(asn).inserted {
                result.append(asn)
            }
        }

        return result
    }

    private static func parseCanonicalOperand(
        _ operand: String
    ) -> AutonomousSystemNumber? {
        // Keep the optional CLI prefix local so ASN parsing needs only swift-cidr.
        let decimal =
            operand.hasPrefix("AS")
            ? String(operand.dropFirst(2))
            : operand

        guard
            let number = AutonomousSystemNumber(decimal),
            decimal == number.description
        else {
            return nil
        }

        return number
    }
}

enum CLIConfigurationBuilder {
    static func make(
        host: String,
        port: Int,
        sources: String?,
        connectTimeoutSeconds: Double,
        queryTimeoutSeconds: Double
    ) throws -> IRRdClientConfiguration {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            throw ValidationError("--host must not be empty.")
        }
        guard (1...65_535).contains(port) else {
            throw ValidationError("--port must be between 1 and 65535.")
        }
        guard connectTimeoutSeconds.isFinite, connectTimeoutSeconds > 0 else {
            throw ValidationError("--connect-timeout must be a finite value greater than zero.")
        }
        guard queryTimeoutSeconds.isFinite, queryTimeoutSeconds > 0 else {
            throw ValidationError("--query-timeout must be a finite value greater than zero.")
        }

        return IRRdClientConfiguration(
            host: normalizedHost,
            port: port,
            sources: try parseSources(sources),
            connectTimeout: .seconds(connectTimeoutSeconds),
            queryTimeout: .seconds(queryTimeoutSeconds)
        )
    }

    private static func parseSources(_ value: String?) throws -> [String]? {
        guard let value else { return nil }

        let sources = value.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !sources.isEmpty, sources.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationError(
                "--sources must be a comma-separated list with no empty source names."
            )
        }

        return sources
    }
}

enum GroupedRouteRenderer {
    // CHANGE: Render the family-bound result directly so IPv4 and IPv6 cannot develop separate
    // formatting behavior while retaining their compile-time prefix types.
    static func render<Family: IPAddressFamily>(
        _ routes: [ASOriginIPRoutes<Family>]
    ) -> String {
        routes.map { routesForASN in
            let body: String
            let routePrefixes = routesForASN.prefixes
            if routePrefixes.isEmpty {
                body = "(no prefixes)"
            } else {
                body = routePrefixes.map(\.description).joined(separator: "\n")
            }

            return "AS\(routesForASN.asn.description):\n\(body)"
        }.joined(separator: "\n\n")
    }
}
