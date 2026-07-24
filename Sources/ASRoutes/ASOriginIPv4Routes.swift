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

/// The distinct IPv4 IRR route-object prefixes visible for one origin AS.
public struct ASOriginIPv4Routes: Sendable, Equatable {
    /// The autonomous system that originates the returned prefixes.
    public let asn: AutonomousSystemNumber

    /// The canonical, exact-deduplicated IPv4 networks in numeric order.
    public let prefixes: [IPv4Network]

    /// Creates an origin-route result for one autonomous system.
    ///
    /// - Parameters:
    ///   - asn: The originating autonomous system.
    ///   - prefixes: The IPv4 networks visible through the selected IRR sources.
    public init(asn: AutonomousSystemNumber, prefixes: [IPv4Network]) {
        self.asn = asn
        self.prefixes = prefixes
    }
}
