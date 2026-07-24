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

import NIOCore
import NIOEmbedded
import Testing

@testable import ASRoutes

@Suite("IRRd frame decoder")
struct IRRdFrameDecoderTests {
    @Test("a successful response decodes across every split boundary")
    func decodesEverySuccessfulFrameSplit() throws {
        let payload = "192.0.2.0/24 198.51.100.0/24"
        let frame = Self.successFrame(payload)

        for splitIndex in 1..<frame.count {
            let channel = Self.makeChannel()

            try Self.write(frame[..<splitIndex], to: channel)
            let prematureResponse = try channel.readInbound(as: IRRdResponse.self)
            #expect(prematureResponse == nil)

            try Self.write(frame[splitIndex...], to: channel)
            let response = try channel.readInbound(as: IRRdResponse.self)
            #expect(
                response
                    == .success(
                        payload: payload,
                        announcedByteCount: payload.utf8.count + 1
                    )
            )
            #expect(try channel.readInbound(as: IRRdResponse.self) == nil)
            _ = try channel.finish()
        }
    }

    @Test("a successful response decodes when delivered one byte at a time")
    func decodesByteByByte() throws {
        let payload = "203.0.113.0/24"
        let channel = Self.makeChannel()

        for byte in Self.successFrame(payload) {
            try Self.write([byte][...], to: channel)
        }

        #expect(
            try channel.readInbound(as: IRRdResponse.self)
                == .success(payload: payload, announcedByteCount: payload.utf8.count + 1)
        )
        _ = try channel.finish()
    }

    @Test("coalesced success, empty, and not-found responses remain distinct")
    func decodesCoalescedFrames() throws {
        let payload = "192.0.2.0/24"
        let channel = Self.makeChannel()
        let frames = Self.successFrame(payload) + Array("C\nD\n".utf8)

        try Self.write(frames[...], to: channel)

        #expect(
            try channel.readInbound(as: IRRdResponse.self)
                == .success(payload: payload, announcedByteCount: payload.utf8.count + 1)
        )
        #expect(try channel.readInbound(as: IRRdResponse.self) == .empty)
        #expect(try channel.readInbound(as: IRRdResponse.self) == .notFound)
        #expect(try channel.readInbound(as: IRRdResponse.self) == nil)
        _ = try channel.finish()
    }

    @Test("the announced length counts UTF-8 bytes, not Swift characters")
    func countsUTF8Bytes() throws {
        let payload = "RADB,RÉSEAUX"
        let channel = Self.makeChannel()

        try Self.write(Self.successFrame(payload)[...], to: channel)

        #expect(
            try channel.readInbound(as: IRRdResponse.self)
                == .success(payload: payload, announcedByteCount: payload.utf8.count + 1)
        )
        _ = try channel.finish()
    }

    @Test("a character-counted multibyte payload is rejected")
    func rejectsCharacterCountInsteadOfByteCount() throws {
        let payload = "RÉSEAUX"
        let incorrectCount = payload.count + 1
        let frame = Array("A\(incorrectCount)\n".utf8) + Array(payload.utf8) + Array("\nC\n".utf8)

        try Self.expectProtocolViolation(frame)
    }

    @Test("server failures surface their typed message")
    func surfacesServerFailure() throws {
        try Self.expectError(
            .serverFailure("access denied"),
            for: Array("F access denied\n".utf8)
        )
    }

    @Test("an announced response over the configured ceiling is rejected immediately")
    func rejectsOversizedResponse() throws {
        try Self.expectError(
            .responseTooLarge(limit: 4, announced: 5),
            for: Array("A5\n".utf8),
            maximumResponseBytes: 4
        )
    }

    @Test("a response exactly at the configured ceiling is accepted")
    func acceptsResponseAtSizeLimit() throws {
        let channel = Self.makeChannel(maximumResponseBytes: 4)
        let payload = "abc"

        try Self.write(Self.successFrame(payload)[...], to: channel)

        #expect(
            try channel.readInbound(as: IRRdResponse.self)
                == .success(payload: payload, announcedByteCount: payload.utf8.count + 1)
        )
        _ = try channel.finish()
    }

    @Test("cumulative responses exactly at the session ceiling are accepted")
    func acceptsResponsesAtSessionSizeLimit() throws {
        let firstPayload = "abc"
        let secondPayload = "de"
        let exactByteCount = firstPayload.utf8.count + 1 + secondPayload.utf8.count + 1
        let channel = Self.makeChannel(maximumSessionResponseBytes: exactByteCount)

        try Self.write(
            (Self.successFrame(firstPayload) + Self.successFrame(secondPayload))[...],
            to: channel
        )

        #expect(
            try channel.readInbound(as: IRRdResponse.self)
                == .success(
                    payload: firstPayload,
                    announcedByteCount: firstPayload.utf8.count + 1
                )
        )
        #expect(
            try channel.readInbound(as: IRRdResponse.self)
                == .success(
                    payload: secondPayload,
                    announcedByteCount: secondPayload.utf8.count + 1
                )
        )
        _ = try channel.finish()
    }

    @Test("a cumulative overage is rejected when its A header arrives")
    func rejectsSessionOverageAtHeader() throws {
        let firstPayload = "abc"
        let firstByteCount = firstPayload.utf8.count + 1
        let secondByteCount = 2
        let limit = firstByteCount + secondByteCount - 1
        let channel = Self.makeChannel(maximumSessionResponseBytes: limit)
        defer { _ = try? channel.finish() }

        try Self.write(Self.successFrame(firstPayload)[...], to: channel)
        #expect(
            try channel.readInbound(as: IRRdResponse.self)
                == .success(payload: firstPayload, announcedByteCount: firstByteCount)
        )

        // The decoder rejects the second response without waiting for either payload byte.
        do {
            try Self.write(Array("A\(secondByteCount)\n".utf8)[...], to: channel)
            Issue.record("Expected the session response ceiling to reject the second header")
        } catch let error as IRRdOriginRouteClientError {
            #expect(
                error
                    == .sessionResponseTooLarge(
                        limit: limit,
                        accumulated: firstByteCount + secondByteCount
                    )
            )
        } catch {
            Issue.record("Expected sessionResponseTooLarge, received \(error)")
        }
    }

    @Test(
        "malformed headers, payloads, and trailers are rejected",
        arguments: [
            Array("\n".utf8),
            Array("X\n".utf8),
            Array("A\n".utf8),
            Array("A12x\n".utf8),
            Array("A0\n".utf8),
            Array("CC\n".utf8),
            Array("DD\n".utf8),
            Array("Fmissing separator\n".utf8),
            Array("A4\nabcXC\n".utf8),
            Array("A4\nabc\nD\n".utf8),
            Array("A999999999999999999999999999999999\n".utf8),
            [
                UInt8(ascii: "A"), UInt8(ascii: "2"), UInt8(ascii: "\n"), 0xff,
                UInt8(ascii: "\n"), UInt8(ascii: "C"), UInt8(ascii: "\n"),
            ],
        ]
    )
    func rejectsMalformedFrame(frame: [UInt8]) throws {
        try Self.expectProtocolViolation(frame)
    }

    @Test(
        "EOF rejects every incomplete frame state",
        arguments: [
            Array("A13".utf8),
            Array("A13\n192.0".utf8),
            Array("A13\n192.0.2.0/24\nC".utf8),
            Array("F failure".utf8),
        ]
    )
    func rejectsTruncatedFrameAtEOF(frame: [UInt8]) throws {
        let channel = Self.makeChannel()
        try Self.write(frame[...], to: channel)

        do {
            _ = try channel.finish()
            Issue.record("Expected a protocolViolation error at EOF")
        } catch IRRdOriginRouteClientError.protocolViolation(
            "connection closed with an incomplete IRRd response"
        ) {
            // Expected.
        } catch {
            Issue.record("Expected protocolViolation, received \(error)")
        }
    }

    @Test("EOF with no partial response is clean")
    func acceptsCleanEOF() throws {
        let channel = Self.makeChannel()
        _ = try channel.finish()
    }
}

extension IRRdFrameDecoderTests {
    fileprivate static func makeChannel(
        maximumResponseBytes: Int = 32 * 1024 * 1024,
        maximumSessionResponseBytes: Int = 64 * 1024 * 1024
    ) -> EmbeddedChannel {
        EmbeddedChannel(
            handler: ByteToMessageHandler(
                IRRdFrameDecoder(
                    maximumResponseBytes: maximumResponseBytes,
                    maximumSessionResponseBytes: maximumSessionResponseBytes
                )
            )
        )
    }

    fileprivate static func successFrame(_ payload: String) -> [UInt8] {
        // CHANGE: The final payload LF is part of IRRd's advertised byte count.
        let announcedByteCount = payload.utf8.count + 1
        return Array("A\(announcedByteCount)\n".utf8) + Array(payload.utf8) + Array("\nC\n".utf8)
    }

    fileprivate static func write(_ bytes: ArraySlice<UInt8>, to channel: EmbeddedChannel) throws {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try channel.writeInbound(buffer)
    }

    fileprivate static func expectProtocolViolation(_ frame: [UInt8]) throws {
        let channel = makeChannel()
        defer { _ = try? channel.finish() }

        do {
            try write(frame[...], to: channel)
            Issue.record("Expected a protocolViolation error")
        } catch IRRdOriginRouteClientError.protocolViolation {
            // Expected.
        } catch {
            Issue.record("Expected protocolViolation, received \(error)")
        }
    }

    fileprivate static func expectError(
        _ expected: IRRdOriginRouteClientError,
        for frame: [UInt8],
        maximumResponseBytes: Int = 32 * 1024 * 1024
    ) throws {
        let channel = makeChannel(maximumResponseBytes: maximumResponseBytes)
        defer { _ = try? channel.finish() }

        do {
            try write(frame[...], to: channel)
            Issue.record("Expected \(expected)")
        } catch let error as IRRdOriginRouteClientError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), received \(error)")
        }
    }
}
