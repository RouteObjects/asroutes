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
import Testing

@testable import ASRoutesCLI

@Suite("Route output renderer")
struct RouteOutputRendererTests {
    @Test("raw IPv4 output globally deduplicates and sorts numerically")
    func rawIPv4Output() throws {
        let routes = [
            ASOriginIPv4Routes(
                asn: AutonomousSystemNumber(701),
                prefixes: try networks([
                    "192.0.2.128/25",
                    "10.0.0.0/8",
                    "192.0.2.0/24",
                ])
            ),
            ASOriginIPv4Routes(asn: AutonomousSystemNumber(702), prefixes: []),
            ASOriginIPv4Routes(
                asn: AutonomousSystemNumber(3_356),
                prefixes: try networks([
                    "192.0.2.0/25",
                    "9.0.0.0/8",
                    "10.0.0.0/8",
                ])
            ),
        ]

        let output = try RouteOutputRenderer.render(routes, format: .raw)

        #expect(
            output
                == Data(
                    """
                    9.0.0.0/8
                    10.0.0.0/8
                    192.0.2.0/24
                    192.0.2.0/25
                    192.0.2.128/25

                    """.utf8
                )
        )
    }

    @Test("grouped output retains a prefix attributed to more than one ASN")
    func groupedOutputRetainsCrossASNDuplicates() throws {
        let routes = [
            ASOriginIPv4Routes(
                asn: AutonomousSystemNumber(701),
                prefixes: try networks(["192.0.2.0/24"])
            ),
            ASOriginIPv4Routes(
                asn: AutonomousSystemNumber(3_356),
                prefixes: try networks(["192.0.2.0/24"])
            ),
        ]

        let output = try RouteOutputRenderer.render(routes, format: .grouped)

        #expect(
            output
                == Data(
                    """
                    AS701:
                    192.0.2.0/24

                    AS3356:
                    192.0.2.0/24

                    """.utf8
                )
        )
    }

    @Test("raw IPv6 output uses numeric ordering and retains more-specifics")
    func rawIPv6Output() throws {
        let routes = [
            ASOriginIPv6Routes(
                asn: AutonomousSystemNumber(701),
                prefixes: try networks([
                    "2001:db8:1::/48",
                    "2001:db8::/32",
                    "2001:db8::/48",
                ])
            ),
            ASOriginIPv6Routes(
                asn: AutonomousSystemNumber(3_356),
                prefixes: try networks([
                    "2001:db7::/32",
                    "2001:db8::/32",
                ])
            ),
        ]

        let output = try RouteOutputRenderer.render(routes, format: .raw)

        #expect(
            output
                == Data(
                    """
                    2001:db7::/32
                    2001:db8::/32
                    2001:db8::/48
                    2001:db8:1::/48

                    """.utf8
                )
        )
    }

    @Test("raw output is zero bytes when no prefix is visible")
    func emptyRawOutput() throws {
        let ipv4Routes = [
            ASOriginIPv4Routes(asn: AutonomousSystemNumber(701), prefixes: []),
            ASOriginIPv4Routes(asn: AutonomousSystemNumber(3_356), prefixes: []),
        ]

        #expect(try RouteOutputRenderer.render(ipv4Routes, format: .raw) == Data())
        #expect(
            try RouteOutputRenderer.render([ASOriginIPv6Routes](), format: .raw) == Data()
        )
    }

    @Test("grouped IPv4 output preserves the human-readable contract")
    func groupedIPv4Output() throws {
        let routes = [
            ASOriginIPv4Routes(
                asn: AutonomousSystemNumber(701),
                prefixes: try networks(["1.2.3.0/24", "4.5.0.0/16"])
            ),
            ASOriginIPv4Routes(asn: AutonomousSystemNumber(702), prefixes: []),
        ]

        let output = try RouteOutputRenderer.render(routes, format: .grouped)

        #expect(
            output
                == Data(
                    """
                    AS701:
                    1.2.3.0/24
                    4.5.0.0/16

                    AS702:
                    (no prefixes)

                    """.utf8
                )
        )
    }

    @Test("grouped IPv6 output preserves group and prefix order")
    func groupedIPv6Output() throws {
        let routes = [
            ASOriginIPv6Routes(
                asn: AutonomousSystemNumber(3_356),
                prefixes: try networks(["2001:db8:1::/48", "2001:db8::/32"])
            )
        ]

        let output = try RouteOutputRenderer.render(routes, format: .grouped)

        #expect(
            output
                == Data(
                    """
                    AS3356:
                    2001:db8:1::/48
                    2001:db8::/32

                    """.utf8
                )
        )
    }

    @Test("JSON IPv4 output preserves ASN attribution, group order, and empty results")
    func jsonIPv4Output() throws {
        let routes = [
            ASOriginIPv4Routes(
                asn: AutonomousSystemNumber(701),
                prefixes: try networks(["192.0.2.0/24"])
            ),
            ASOriginIPv4Routes(asn: AutonomousSystemNumber(64_500), prefixes: []),
            ASOriginIPv4Routes(
                asn: AutonomousSystemNumber(3_356),
                prefixes: try networks(["192.0.2.0/24", "192.0.2.128/25"])
            ),
        ]

        let output = try RouteOutputRenderer.render(routes, format: .json)

        #expect(
            output
                == Data(
                    """
                    [
                      {
                        "asn" : 701,
                        "prefixes" : [
                          "192.0.2.0/24"
                        ]
                      },
                      {
                        "asn" : 64500,
                        "prefixes" : [

                        ]
                      },
                      {
                        "asn" : 3356,
                        "prefixes" : [
                          "192.0.2.0/24",
                          "192.0.2.128/25"
                        ]
                      }
                    ]

                    """.utf8
                )
        )
        #expect(
            try JSONDecoder().decode([DecodedRouteGroup].self, from: output)
                == [
                    DecodedRouteGroup(asn: 701, prefixes: ["192.0.2.0/24"]),
                    DecodedRouteGroup(asn: 64_500, prefixes: []),
                    DecodedRouteGroup(
                        asn: 3_356,
                        prefixes: ["192.0.2.0/24", "192.0.2.128/25"]
                    ),
                ]
        )
    }

    @Test("JSON IPv6 output uses canonical unescaped prefix strings")
    func jsonIPv6Output() throws {
        let routes = [
            ASOriginIPv6Routes(
                asn: AutonomousSystemNumber(UInt32.max),
                prefixes: try networks(["2001:db8::/32", "2001:db8:1::/48"])
            ),
            ASOriginIPv6Routes(asn: AutonomousSystemNumber(701), prefixes: []),
        ]

        let output = try RouteOutputRenderer.render(routes, format: .json)

        #expect(
            output
                == Data(
                    """
                    [
                      {
                        "asn" : 4294967295,
                        "prefixes" : [
                          "2001:db8::/32",
                          "2001:db8:1::/48"
                        ]
                      },
                      {
                        "asn" : 701,
                        "prefixes" : [

                        ]
                      }
                    ]

                    """.utf8
                )
        )
        #expect(
            try JSONDecoder().decode([DecodedRouteGroup].self, from: output)
                == [
                    DecodedRouteGroup(
                        asn: UInt32.max,
                        prefixes: ["2001:db8::/32", "2001:db8:1::/48"]
                    ),
                    DecodedRouteGroup(asn: 701, prefixes: []),
                ]
        )
    }

    @Test("an empty JSON result is a valid array followed by a line feed")
    func emptyJSONOutput() throws {
        let output = try RouteOutputRenderer.render([ASOriginIPv4Routes](), format: .json)

        #expect(output == Data("[\n\n]\n".utf8))
    }

    private func networks<Family: IPAddressFamily>(
        _ descriptions: [String]
    ) throws -> [IPNetwork<Family>] {
        try descriptions.map { try #require(IPNetwork<Family>($0)) }
    }
}

private struct DecodedRouteGroup: Decodable, Equatable {
    let asn: UInt32
    let prefixes: [String]
}
