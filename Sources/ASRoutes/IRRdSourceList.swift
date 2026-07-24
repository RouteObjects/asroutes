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

enum IRRdSourceList {
    static func normalizeConfigured(_ sources: [String]?) throws -> [String]? {
        guard let sources else { return nil }
        guard !sources.isEmpty else {
            throw IRRdOriginRouteClientError.invalidConfiguration(
                "an explicit source list must not be empty"
            )
        }

        var normalized: [String] = []
        normalized.reserveCapacity(sources.count)
        var seen = Set<String>()

        for source in sources {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let token = normalizeToken(trimmed) else {
                throw IRRdOriginRouteClientError.invalidConfiguration(
                    "source names must contain only ASCII letters, digits, and interior hyphens"
                )
            }
            if seen.insert(token).inserted {
                normalized.append(token)
            }
        }

        return normalized
    }

    static func parseDiscovered(_ payload: String) throws -> [String] {
        let fields = payload.split(separator: ",", omittingEmptySubsequences: false)
        guard !payload.isEmpty, !fields.isEmpty else {
            throw IRRdOriginRouteClientError.protocolViolation(
                "!s-lc returned an empty source list"
            )
        }

        var normalized: [String] = []
        normalized.reserveCapacity(fields.count)
        var seen = Set<String>()

        for field in fields {
            // CHANGE: A server-supplied source name is interpolated into the next `!s`
            // command, so accept only IRRd's configured source-name grammar.
            guard let token = normalizeToken(String(field)) else {
                throw IRRdOriginRouteClientError.protocolViolation(
                    "!s-lc returned a malformed source list"
                )
            }
            if seen.insert(token).inserted {
                normalized.append(token)
            }
        }

        return normalized
    }

    private static func normalizeToken(_ value: String) -> String? {
        guard value.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }

        let bytes = Array(value.uppercased().utf8)
        guard
            bytes.count >= 2,
            isASCIILetter(bytes[0]),
            isASCIIAlphaNumeric(bytes[bytes.count - 1]),
            bytes.allSatisfy({ isASCIIAlphaNumeric($0) || $0 == UInt8(ascii: "-") })
        else {
            return nil
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        isASCIILetter(byte)
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }
}
