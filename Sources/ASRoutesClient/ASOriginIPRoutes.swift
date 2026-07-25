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

/// The IPv4 specialization of ``ASOriginIPRoutes``.
public typealias ASOriginIPv4Routes = ASOriginIPRoutes<V4>

/// The IPv6 specialization of ``ASOriginIPRoutes``.
public typealias ASOriginIPv6Routes = ASOriginIPRoutes<V6>

/// The IRR route-object prefixes visible for one origin AS and IP address family.
///
/// `Family` keeps every prefix in a result in the same address family at compile time. The
/// ``ASOriginIPv4Routes`` and ``ASOriginIPv6Routes`` aliases provide convenient names for the
/// specializations returned by ``IRRdOriginRouteClient``.
public struct ASOriginIPRoutes<Family: IPAddressFamily>: Sendable, Equatable {
    /// The autonomous system that originates the returned prefixes.
    public let asn: AutonomousSystemNumber

    /// The family-bound networks associated with the autonomous system.
    ///
    /// Results returned by ``IRRdOriginRouteClient`` are canonical, exact-deduplicated, and
    /// numerically sorted. Values supplied directly to the initializer are preserved unchanged.
    public let prefixes: [IPNetwork<Family>]

    /// Creates an origin-route result for one autonomous system.
    ///
    /// - Parameters:
    ///   - asn: The originating autonomous system.
    ///   - prefixes: The family-bound networks to associate with the autonomous system. Their
    ///     order and exact contents are preserved.
    public init(asn: AutonomousSystemNumber, prefixes: [IPNetwork<Family>]) {
        self.asn = asn
        self.prefixes = prefixes
    }
}
