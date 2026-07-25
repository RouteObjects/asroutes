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

@Suite("Family-generic AS origin routes")
struct ASOriginIPRoutesTests {
    @Test("constructs family-bound IPv4 and IPv6 results directly")
    func constructsBothFamilies() throws {
        let ipv4Prefix = try #require(IPv4Network("192.0.2.0/24"))
        let ipv6Prefix = try #require(IPv6Network("2001:db8::/32"))

        let ipv4 = ASOriginIPRoutes<V4>(
            asn: AutonomousSystemNumber(701),
            prefixes: [ipv4Prefix]
        )
        let ipv6 = ASOriginIPRoutes<V6>(
            asn: AutonomousSystemNumber(701),
            prefixes: [ipv6Prefix]
        )

        let typedIPv4Prefixes: [IPNetwork<V4>] = ipv4.prefixes
        let typedIPv6Prefixes: [IPNetwork<V6>] = ipv6.prefixes
        #expect(typedIPv4Prefixes == [ipv4Prefix])
        #expect(typedIPv6Prefixes == [ipv6Prefix])
        requireSendable(ipv4)
        requireSendable(ipv6)
    }

    @Test("IPv4 and IPv6 aliases are their generic specializations")
    func aliasesMatchGenericSpecializations() throws {
        let ipv4Alias = ASOriginIPv4Routes(
            asn: AutonomousSystemNumber(64_496),
            prefixes: [try #require(IPv4Network("198.51.100.0/24"))]
        )
        let ipv6Alias = ASOriginIPv6Routes(
            asn: AutonomousSystemNumber(64_496),
            prefixes: [try #require(IPv6Network("2001:db8:1::/48"))]
        )

        let ipv4Generic: ASOriginIPRoutes<V4> = ipv4Alias
        let ipv6Generic: ASOriginIPRoutes<V6> = ipv6Alias
        let ipv4RoundTrip: ASOriginIPv4Routes = ipv4Generic
        let ipv6RoundTrip: ASOriginIPv6Routes = ipv6Generic

        #expect(ipv4RoundTrip == ipv4Alias)
        #expect(ipv6RoundTrip == ipv6Alias)
    }

    @Test("aliases infer their family for empty prefix arrays")
    func aliasesInferEmptyPrefixArrays() {
        let ipv4 = ASOriginIPv4Routes(
            asn: AutonomousSystemNumber(701),
            prefixes: []
        )
        let ipv6 = ASOriginIPv6Routes(
            asn: AutonomousSystemNumber(701),
            prefixes: []
        )

        let typedIPv4Prefixes: [IPv4Network] = ipv4.prefixes
        let typedIPv6Prefixes: [IPv6Network] = ipv6.prefixes
        #expect(typedIPv4Prefixes.isEmpty)
        #expect(typedIPv6Prefixes.isEmpty)
    }

    @Test("public construction preserves exact prefix order and duplicates")
    func preservesCallerSuppliedPrefixes() throws {
        let ipv4Prefixes = [
            try #require(IPv4Network("192.0.2.128/25")),
            try #require(IPv4Network("10.0.0.0/8")),
            try #require(IPv4Network("192.0.2.128/25")),
        ]
        let ipv6Prefixes = [
            try #require(IPv6Network("2001:db8:2::/48")),
            try #require(IPv6Network("2001:db8::/32")),
            try #require(IPv6Network("2001:db8:2::/48")),
        ]

        let ipv4 = ASOriginIPRoutes<V4>(
            asn: AutonomousSystemNumber(701),
            prefixes: ipv4Prefixes
        )
        let ipv6 = ASOriginIPRoutes<V6>(
            asn: AutonomousSystemNumber(701),
            prefixes: ipv6Prefixes
        )

        #expect(ipv4.prefixes == ipv4Prefixes)
        #expect(ipv6.prefixes == ipv6Prefixes)
    }

    @Test("equality includes the ASN and ordered prefix array")
    func equalityUsesAllStoredState() throws {
        let prefixes = [try #require(IPv4Network("192.0.2.0/24"))]
        let routes = ASOriginIPRoutes<V4>(
            asn: AutonomousSystemNumber(701),
            prefixes: prefixes
        )

        #expect(
            routes
                == ASOriginIPRoutes<V4>(
                    asn: AutonomousSystemNumber(701),
                    prefixes: prefixes
                )
        )
        #expect(
            routes
                != ASOriginIPRoutes<V4>(
                    asn: AutonomousSystemNumber(702),
                    prefixes: prefixes
                )
        )
        #expect(
            routes
                != ASOriginIPRoutes<V4>(
                    asn: AutonomousSystemNumber(701),
                    prefixes: []
                )
        )
    }
}

private func requireSendable<Value: Sendable>(_: Value) {}
