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

import Foundation

/// Configuration for an IRRd raw-Whois origin-route query session.
public struct IRRdClientConfiguration: Sendable, Equatable {
    /// The IRRd host to query.
    public var host: String

    /// The raw-Whois TCP port.
    public var port: Int

    /// An optional explicit IRR source list. `nil` uses the server-selected sources.
    public var sources: [String]?

    /// The maximum time allowed to establish the TCP connection.
    public var connectTimeout: Duration

    /// The maximum time allowed for an individual IRRd response.
    public var queryTimeout: Duration

    /// The largest accepted individual `A` response, including its terminating line feed.
    public var maximumResponseBytes: Int

    /// The largest cumulative total of `A` responses, including each terminating line feed.
    public var maximumSessionResponseBytes: Int

    /// Creates the configuration for one IRRd TCP session.
    ///
    /// Both byte limits measure the server-announced payload length, which includes the final
    /// line feed but excludes the `A` header and `C` completion marker.
    ///
    /// - Parameters:
    ///   - host: The IRRd host to query.
    ///   - port: The raw-Whois TCP port.
    ///   - sources: Explicit IRR sources, or `nil` to use the server-selected sources.
    ///   - connectTimeout: The maximum connection-establishment duration.
    ///   - queryTimeout: The maximum duration for each complete IRRd response.
    ///   - maximumResponseBytes: The per-`A`-response byte ceiling.
    ///   - maximumSessionResponseBytes: The cumulative `A`-response byte ceiling.
    public init(
        host: String = "rr.ntt.net",
        port: Int = 43,
        sources: [String]? = nil,
        connectTimeout: Duration = .seconds(10),
        queryTimeout: Duration = .seconds(30),
        maximumResponseBytes: Int = 32 * 1024 * 1024,
        maximumSessionResponseBytes: Int = 64 * 1024 * 1024
    ) {
        self.host = host
        self.port = port
        self.sources = sources
        self.connectTimeout = connectTimeout
        self.queryTimeout = queryTimeout
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumSessionResponseBytes = maximumSessionResponseBytes
    }
}
