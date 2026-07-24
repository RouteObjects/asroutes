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

import Testing

@testable import ASRoutes

@Suite("IRRd origin-route payload parsing")
struct IRRdOriginRouteClientTests {
    @Test("client configuration defaults bound individual and cumulative responses")
    func defaultsResponseLimits() {
        let configuration = IRRdClientConfiguration()

        #expect(configuration.maximumResponseBytes == 32 * 1024 * 1024)
        #expect(configuration.maximumSessionResponseBytes == 64 * 1024 * 1024)
    }

    @Test(
        "nonpositive response limits are rejected before connecting",
        arguments: [
            IRRdClientConfiguration(maximumResponseBytes: 0),
            IRRdClientConfiguration(maximumResponseBytes: -1),
            IRRdClientConfiguration(maximumSessionResponseBytes: 0),
            IRRdClientConfiguration(maximumSessionResponseBytes: -1),
        ]
    )
    func rejectsNonpositiveResponseLimits(configuration: IRRdClientConfiguration) async {
        let client = IRRdOriginRouteClient(configuration: configuration)

        do {
            _ = try await client.ipv4Routes(for: [])
            Issue.record("Expected response-limit validation to fail")
        } catch IRRdOriginRouteClientError.invalidConfiguration {
            // Expected.
        } catch {
            Issue.record("Expected invalidConfiguration, received \(error)")
        }
    }

    @Test("the aggregate-limit error has a stable diagnostic")
    func describesAggregateLimitError() {
        let error = IRRdOriginRouteClientError.sessionResponseTooLarge(
            limit: 64,
            accumulated: 65
        )

        #expect(
            error.description
                == "IRRd session received 65 response bytes, exceeding the 64-byte limit"
        )
    }

    @Test("prefixes are sorted, exact-deduplicated, and not aggregated")
    func parsesDeterministicallyWithoutAggregation() throws {
        let prefixes = try IRRdOriginRouteClient.parseIPv4Prefixes(
            """
            192.0.2.128/25 10.0.0.0/8 192.0.2.0/25
            192.0.2.0/24 192.0.2.128/25
            """
        )

        // CHANGE: Both /25s remain even though the /24 covers them; only the exact duplicate is removed.
        #expect(
            prefixes.map(\.description) == [
                "10.0.0.0/8",
                "192.0.2.0/24",
                "192.0.2.0/25",
                "192.0.2.128/25",
            ])
    }

    @Test("invalid CIDR payloads fail the complete response")
    func rejectsInvalidCIDR() {
        #expect(throws: IRRdOriginRouteClientError.invalidPrefix("not-a-prefix")) {
            try IRRdOriginRouteClient.parseIPv4Prefixes(
                "192.0.2.0/24 not-a-prefix 198.51.100.0/24"
            )
        }
    }

    @Test("IPv6 prefixes are rejected by the IPv4-only client")
    func rejectsIPv6Payload() {
        #expect(throws: IRRdOriginRouteClientError.invalidPrefix("2001:db8::/32")) {
            try IRRdOriginRouteClient.parseIPv4Prefixes("2001:db8::/32")
        }
    }

    @Test("an empty successful payload yields no prefixes")
    func acceptsEmptyPayload() throws {
        #expect(try IRRdOriginRouteClient.parseIPv4Prefixes("").isEmpty)
    }

    @Test("IPv6 prefixes are canonical, numerically sorted, exact-deduplicated, and not aggregated")
    func parsesIPv6DeterministicallyWithoutAggregation() throws {
        let prefixes = try IRRdOriginRouteClient.parseIPv6Prefixes(
            """
            2001:db8:10::/48 2001:db8:2::/49 2001:db8:2::/48
            2001:0db8:0:0:1234::/32 2001:db8::/32 2001:db8:2::/49
            """
        )

        // CHANGE: The /48 and covered /49 both remain, while canonicalization makes equivalent
        // /32 values exact duplicates and numeric sorting puts :2 before :10.
        #expect(
            prefixes.map(\.description) == [
                "2001:db8::/32",
                "2001:db8:2::/48",
                "2001:db8:2::/49",
                "2001:db8:10::/48",
            ])
    }

    @Test("invalid IPv6 CIDR payloads fail the complete response")
    func rejectsInvalidIPv6CIDR() {
        #expect(throws: IRRdOriginRouteClientError.invalidPrefix("not-an-ipv6-prefix")) {
            try IRRdOriginRouteClient.parseIPv6Prefixes(
                "2001:db8::/32 not-an-ipv6-prefix 2001:db8:1::/48"
            )
        }
    }

    @Test("IPv4 prefixes are rejected by the IPv6 client")
    func rejectsIPv4Payload() {
        #expect(throws: IRRdOriginRouteClientError.invalidPrefix("192.0.2.0/24")) {
            try IRRdOriginRouteClient.parseIPv6Prefixes("192.0.2.0/24")
        }
    }

    @Test("an empty successful IPv6 payload yields no prefixes")
    func acceptsEmptyIPv6Payload() throws {
        #expect(try IRRdOriginRouteClient.parseIPv6Prefixes("").isEmpty)
    }

    @Test("configured source names are normalized and exact-deduplicated")
    func normalizesConfiguredSources() throws {
        #expect(
            try IRRdSourceList.normalizeConfigured([" radb ", "RIPE-NONAUTH", "RADB"])
                == ["RADB", "RIPE-NONAUTH"]
        )
    }

    @Test("configured source names use IRRd's protocol-safe grammar")
    func rejectsUnsafeConfiguredSources() {
        let invalidLists = [
            [String](),
            ["A"],
            ["-RADB"],
            ["RADB-"],
            ["RAD B"],
            ["RADB\tALT"],
            ["RADB\n!q"],
            ["RÁDB"],
        ]

        for sources in invalidLists {
            #expect(throws: IRRdOriginRouteClientError.self) {
                try IRRdSourceList.normalizeConfigured(sources)
            }
        }
    }

    @Test("server-discovered source names cannot inject a follow-up command")
    func rejectsUnsafeDiscoveredSources() {
        #expect(
            throws: IRRdOriginRouteClientError.protocolViolation(
                "!s-lc returned a malformed source list"
            )
        ) {
            try IRRdSourceList.parseDiscovered("DEFAULT,ALT\n!q")
        }
    }
}
