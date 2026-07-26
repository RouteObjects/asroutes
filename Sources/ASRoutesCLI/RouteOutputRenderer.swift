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

enum RouteOutputFormat: Sendable, CaseIterable {
    case raw
    case grouped
    case json
}

enum RouteOutputRenderer {
    static func render<Family: IPAddressFamily>(
        _ routes: [ASOriginIPRoutes<Family>],
        format: RouteOutputFormat
    ) throws -> Data {
        switch format {
        case .raw:
            return renderRaw(routes)
        case .grouped:
            return renderGrouped(routes)
        case .json:
            return try renderJSON(routes)
        }
    }

    private static func renderRaw<Family: IPAddressFamily>(
        _ routes: [ASOriginIPRoutes<Family>]
    ) -> Data {
        var uniquePrefixes = Set<IPNetwork<Family>>()
        for routesForASN in routes {
            uniquePrefixes.formUnion(routesForASN.prefixes)
        }

        // CHANGE: Raw output intentionally discards ASN attribution, so exact duplicates can be
        // removed across groups before producing one deterministic pipeline-oriented prefix set.
        let sortedPrefixes = uniquePrefixes.sorted { lhs, rhs in
            if lhs.prefix != rhs.prefix {
                return lhs.prefix < rhs.prefix
            }
            return lhs.prefixLength < rhs.prefixLength
        }

        return lineData(sortedPrefixes.map(\.description))
    }

    private static func renderGrouped<Family: IPAddressFamily>(
        _ routes: [ASOriginIPRoutes<Family>]
    ) -> Data {
        let groups = routes.map { routesForASN in
            let body =
                routesForASN.prefixes.isEmpty
                ? "(no prefixes)"
                : routesForASN.prefixes.map(\.description).joined(separator: "\n")
            return "AS\(routesForASN.asn.description):\n\(body)"
        }

        guard !groups.isEmpty else { return Data() }
        return Data((groups.joined(separator: "\n\n") + "\n").utf8)
    }

    private static func renderJSON<Family: IPAddressFamily>(
        _ routes: [ASOriginIPRoutes<Family>]
    ) throws -> Data {
        let payload = routes.map(JSONRouteGroup.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        var data = try encoder.encode(payload)
        data.append(0x0A)
        return data
    }

    private static func lineData(_ lines: [String]) -> Data {
        guard !lines.isEmpty else { return Data() }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

private struct JSONRouteGroup<Family: IPAddressFamily>: Encodable {
    let asn: AutonomousSystemNumber
    let prefixes: [IPNetwork<Family>]

    init(_ routes: ASOriginIPRoutes<Family>) {
        self.asn = routes.asn
        self.prefixes = routes.prefixes
    }
}
