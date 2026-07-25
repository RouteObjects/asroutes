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

/// Errors produced while querying or decoding an IRRd origin-route response.
public enum IRRdOriginRouteClientError: Error, Sendable, Equatable {
    /// One or more client configuration values are invalid.
    case invalidConfiguration(String)

    /// The named connection or response operation exceeded its configured timeout.
    case timeout(operation: String)

    /// The underlying transport failed for the supplied diagnostic reason.
    case transportFailure(String)

    /// One `A` response exceeded the per-response ceiling.
    ///
    /// Both values count the server-announced bytes, including the payload's terminating line feed.
    case responseTooLarge(limit: Int, announced: Int)

    /// Cumulative `A` responses exceeded the session ceiling.
    ///
    /// `accumulated` includes the response that crossed the limit and every `A` response seen
    /// earlier in the session, including source discovery and terminating line feeds.
    case sessionResponseTooLarge(limit: Int, accumulated: Int)

    /// The server response violated IRRd framing or session expectations.
    case protocolViolation(String)

    /// The IRRd server rejected a command with the supplied message.
    case serverFailure(String)

    /// A route response contained a malformed prefix or a prefix from the wrong address family.
    case invalidPrefix(String)
}

extension IRRdOriginRouteClientError: CustomStringConvertible {
    /// A human-readable diagnostic suitable for CLI error output.
    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid IRRd client configuration: \(message)"
        case .timeout(let operation):
            return "IRRd \(operation) timed out"
        case .transportFailure(let message):
            return "IRRd transport failed: \(message)"
        case .responseTooLarge(let limit, let announced):
            return "IRRd response announced \(announced) bytes, exceeding the \(limit)-byte limit"
        case .sessionResponseTooLarge(let limit, let accumulated):
            return
                "IRRd session received \(accumulated) response bytes, exceeding the \(limit)-byte limit"
        case .protocolViolation(let message):
            return "Invalid IRRd response: \(message)"
        case .serverFailure(let message):
            return "IRRd server rejected the query: \(message)"
        case .invalidPrefix(let prefix):
            return "IRRd returned an invalid IP prefix: \(prefix)"
        }
    }
}
