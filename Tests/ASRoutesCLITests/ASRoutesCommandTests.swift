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
import Testing

@testable import ASRoutesCLI

@Suite("asroutes CLI")
struct ASRoutesCommandTests {
    @Test("the CLI reports the release version")
    func reportsReleaseVersion() {
        #expect(ASRoutesCommand.version == "0.1.0")
        #expect(ASRoutesCommand.configuration.version == ASRoutesCommand.version)
    }

    @Test("ArgumentParser maps the documented CLI surface")
    func parsesCommandLineOptionsAndOperands() throws {
        let command = try ASRoutesCommand.parse([
            "--host", "rr.example.net",
            "--port", "4443",
            "--sources", "RADB,RIPE",
            "--connect-timeout", "2.5",
            "--query-timeout", "7",
            "AS701", "702",
        ])

        #expect(command.host == "rr.example.net")
        #expect(command.port == 4_443)
        #expect(command.sources == "RADB,RIPE")
        #expect(command.connectTimeout == 2.5)
        #expect(command.queryTimeout == 7)
        #expect(command.asnOperands == ["AS701", "702"])
        #expect(command.addressFamily == .ipv4)
    }

    @Test("address-family flags select IPv4 or IPv6")
    func parsesAddressFamilyFlags() throws {
        #expect(try ASRoutesCommand.parse(["-4", "AS701"]).addressFamily == .ipv4)
        #expect(try ASRoutesCommand.parse(["-6", "AS701"]).addressFamily == .ipv6)
    }

    @Test("IPv4 and IPv6 flags are mutually exclusive")
    func rejectsConflictingAddressFamilyFlags() {
        #expect(throws: (any Error).self) {
            try ASRoutesCommand.parse(["-4", "-6", "AS701"])
        }
    }

    @Test("address-family flags have no long aliases", arguments: ["--ipv4", "--ipv6"])
    func rejectsLongAddressFamilyAliases(flag: String) {
        #expect(throws: (any Error).self) {
            try ASRoutesCommand.parse([flag, "AS701"])
        }
    }

    @Test("ASN operands accept canonical bare and uppercase AS-prefixed forms")
    func parsesCanonicalASNOperands() throws {
        let asns = try ASNOperandParser.parse(["0", "AS701", "4294967295"])

        #expect(
            asns == [
                AutonomousSystemNumber(0),
                AutonomousSystemNumber(701),
                AutonomousSystemNumber(UInt32.max),
            ])
        #expect(try ASNOperandParser.parse(["AS0"]) == [AutonomousSystemNumber(0)])
        #expect(
            try ASNOperandParser.parse(["AS4294967295"]) == [
                AutonomousSystemNumber(UInt32.max)
            ]
        )
    }

    @Test("duplicate ASN operands retain first-seen order")
    func removesDuplicateASNOperands() throws {
        let asns = try ASNOperandParser.parse([
            "AS702", "701", "702", "AS701", "AS4294967295", "701",
        ])

        #expect(
            asns == [
                AutonomousSystemNumber(702),
                AutonomousSystemNumber(701),
                AutonomousSystemNumber(UInt32.max),
            ])
    }

    @Test(
        "noncanonical, malformed, and AS-set operands are rejected",
        arguments: [
            "", "AS", "AS-EXAMPLE", "AS701x",
            " 701", "701 ", " AS701", "AS701 ",
            "+701", "-701", "AS+701", "AS-701",
            "1.10", "AS1.10",
            "00", "000701", "AS00", "AS000701",
            "as701", "As701", "aS701",
            "4294967296", "AS4294967296",
        ]
    )
    func rejectsInvalidASNOperand(operand: String) {
        #expect(throws: (any Error).self) {
            try ASNOperandParser.parse([operand])
        }
    }

    @Test("at least one ASN operand is required")
    func requiresASNOperand() {
        #expect(throws: (any Error).self) {
            try ASNOperandParser.parse([])
        }
    }

    @Test("CLI configuration normalizes host, sources, and timeouts")
    func buildsClientConfiguration() throws {
        let configuration = try CLIConfigurationBuilder.make(
            host: " rr.example.net ",
            port: 43,
            sources: "RADB, RIPE",
            connectTimeoutSeconds: 2.5,
            queryTimeoutSeconds: 7
        )

        #expect(configuration.host == "rr.example.net")
        #expect(configuration.port == 43)
        #expect(configuration.sources == ["RADB", "RIPE"])
        #expect(configuration.connectTimeout == .seconds(2.5))
        #expect(configuration.queryTimeout == .seconds(7))
        #expect(configuration.maximumResponseBytes == 32 * 1024 * 1024)
        #expect(configuration.maximumSessionResponseBytes == 64 * 1024 * 1024)
    }

    @Test("omitting sources preserves server source selection")
    func preservesServerSelectedSources() throws {
        let configuration = try CLIConfigurationBuilder.make(
            host: "rr.example.net",
            port: 43,
            sources: nil,
            connectTimeoutSeconds: 10,
            queryTimeoutSeconds: 30
        )

        #expect(configuration.sources == nil)
    }

    @Test(
        "invalid CLI configuration is rejected",
        arguments: [
            InvalidConfiguration(host: "", port: 43, sources: nil, connectTimeout: 10, queryTimeout: 30),
            InvalidConfiguration(
                host: "host", port: 0, sources: nil, connectTimeout: 10, queryTimeout: 30),
            InvalidConfiguration(
                host: "host", port: 65_536, sources: nil, connectTimeout: 10, queryTimeout: 30),
            InvalidConfiguration(
                host: "host", port: 43, sources: "RADB,", connectTimeout: 10, queryTimeout: 30),
            InvalidConfiguration(
                host: "host", port: 43, sources: nil, connectTimeout: 0, queryTimeout: 30),
            InvalidConfiguration(
                host: "host", port: 43, sources: nil, connectTimeout: 10, queryTimeout: -.infinity),
        ]
    )
    func rejectsInvalidConfiguration(value: InvalidConfiguration) {
        #expect(throws: (any Error).self) {
            try CLIConfigurationBuilder.make(
                host: value.host,
                port: value.port,
                sources: value.sources,
                connectTimeoutSeconds: value.connectTimeout,
                queryTimeoutSeconds: value.queryTimeout
            )
        }
    }

    @Test("grouped output preserves result order and inserts one blank line")
    func rendersGroupedOutput() {
        let routes = [
            ASOriginIPv4Routes(
                asn: AutonomousSystemNumber(701),
                prefixes: [
                    .init("1.2.3.0/24")!,
                    .init("4.5.0.0/16")!,
                ]
            ),
            ASOriginIPv4Routes(asn: AutonomousSystemNumber(702), prefixes: []),
        ]

        #expect(
            GroupedRouteRenderer.render(routes) == """
                AS701:
                1.2.3.0/24
                4.5.0.0/16

                AS702:
                (no prefixes)
                """
        )
    }

    @Test("IPv6 grouped output uses the existing text contract")
    func rendersIPv6GroupedOutput() {
        let routes = [
            ASOriginIPv6Routes(
                asn: AutonomousSystemNumber(701),
                prefixes: [
                    .init("2001:db8::/32")!,
                    .init("2001:db8:1::/48")!,
                ]
            ),
            ASOriginIPv6Routes(asn: AutonomousSystemNumber(702), prefixes: []),
        ]

        #expect(
            GroupedRouteRenderer.render(routes) == """
                AS701:
                2001:db8::/32
                2001:db8:1::/48

                AS702:
                (no prefixes)
                """
        )
    }

    @Test("application dispatches to the selected typed lookup")
    func dispatchesSelectedAddressFamily() async throws {
        let calls = LookupCallRecorder()
        let configuration = IRRdClientConfiguration(host: "rr.example.net")
        let asns = [AutonomousSystemNumber(701)]
        let application = ASRoutesApplication(
            routeLookup: { _, asns in
                await calls.recordIPv4(asns)
                return []
            },
            ipv6RouteLookup: { _, asns in
                await calls.recordIPv6(asns)
                return []
            },
            outputWriter: { _ in }
        )

        try await application.run(configuration: configuration, asns: asns)
        try await application.run(
            configuration: configuration,
            asns: asns,
            addressFamily: .ipv6
        )

        let snapshot = await calls.snapshot()
        #expect(snapshot.ipv4 == [asns])
        #expect(snapshot.ipv6 == [asns])
    }

    @Test("no results render as an empty buffer")
    func rendersNoResults() {
        #expect(GroupedRouteRenderer.render([ASOriginIPv4Routes]()) == "")
        #expect(GroupedRouteRenderer.render([ASOriginIPv6Routes]()) == "")
    }
}

struct InvalidConfiguration: Sendable {
    let host: String
    let port: Int
    let sources: String?
    let connectTimeout: Double
    let queryTimeout: Double
}

private actor LookupCallRecorder {
    private var ipv4Calls: [[AutonomousSystemNumber]] = []
    private var ipv6Calls: [[AutonomousSystemNumber]] = []

    func recordIPv4(_ asns: [AutonomousSystemNumber]) {
        ipv4Calls.append(asns)
    }

    func recordIPv6(_ asns: [AutonomousSystemNumber]) {
        ipv6Calls.append(asns)
    }

    func snapshot() -> (
        ipv4: [[AutonomousSystemNumber]],
        ipv6: [[AutonomousSystemNumber]]
    ) {
        (ipv4Calls, ipv6Calls)
    }
}
