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

/// One complete response in IRRd's compact, byte-counted query protocol.
enum IRRdResponse: Sendable, Equatable {
    // CHANGE: Preserve the exact server-announced length with the decoded payload so downstream
    // protocol handling never has to reconstruct IRRd's terminating-line-feed byte semantics.
    case success(payload: String, announcedByteCount: Int)
    case empty
    case notFound
}

/// Decodes the response framing used by IRRd-style `!` queries.
struct IRRdFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = IRRdResponse

    private enum State: Sendable, Equatable {
        case awaitingHeader
        case awaitingPayload(byteCount: Int)
    }

    private static let maximumHeaderBytes = 8 * 1024

    private let maximumResponseBytes: Int
    private let maximumSessionResponseBytes: Int
    private var sessionResponseBytes = 0
    private var state: State = .awaitingHeader

    init(maximumResponseBytes: Int, maximumSessionResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumSessionResponseBytes = maximumSessionResponseBytes
    }

    mutating func decode(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer
    ) throws -> DecodingState {
        switch state {
        case .awaitingHeader:
            return try decodeHeader(context: context, buffer: &buffer)
        case .awaitingPayload(let byteCount):
            return try decodePayload(byteCount: byteCount, context: context, buffer: &buffer)
        }
    }

    mutating func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        while try decode(context: context, buffer: &buffer) == .continue {}

        guard state == .awaitingHeader, buffer.readableBytes == 0 else {
            throw IRRdOriginRouteClientError.protocolViolation(
                "connection closed with an incomplete IRRd response"
            )
        }
        return .needMoreData
    }

    private mutating func decodeHeader(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer
    ) throws -> DecodingState {
        guard let newlineIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            guard buffer.readableBytes <= Self.maximumHeaderBytes else {
                throw IRRdOriginRouteClientError.protocolViolation(
                    "response header exceeded \(Self.maximumHeaderBytes) bytes without a line feed"
                )
            }
            return .needMoreData
        }

        let headerLength = buffer.readableBytesView.distance(
            from: buffer.readableBytesView.startIndex,
            to: newlineIndex
        )
        guard headerLength <= Self.maximumHeaderBytes else {
            throw IRRdOriginRouteClientError.protocolViolation(
                "response header exceeded \(Self.maximumHeaderBytes) bytes"
            )
        }
        guard let header = buffer.readBytes(length: headerLength) else {
            return .needMoreData
        }
        buffer.moveReaderIndex(forwardBy: 1)

        guard let status = header.first else {
            throw IRRdOriginRouteClientError.protocolViolation("response header was empty")
        }

        switch status {
        case UInt8(ascii: "A"):
            let byteCount = try parseAnnouncedByteCount(header.dropFirst())
            guard byteCount > 0 else {
                throw IRRdOriginRouteClientError.protocolViolation(
                    "a successful response must announce at least its terminating line feed"
                )
            }
            guard byteCount <= maximumResponseBytes else {
                throw IRRdOriginRouteClientError.responseTooLarge(
                    limit: maximumResponseBytes,
                    announced: byteCount
                )
            }
            // CHANGE: Charge the advertised bytes at the header boundary, before the decoder
            // waits for, materializes, or queues a payload that would exceed the session ceiling.
            try recordSuccessfulResponse(byteCount: byteCount)

            state = .awaitingPayload(byteCount: byteCount)
            return .continue

        case UInt8(ascii: "C"):
            guard header.count == 1 else {
                throw IRRdOriginRouteClientError.protocolViolation(
                    "empty-success response contained unexpected header data"
                )
            }
            context.fireChannelRead(wrapInboundOut(.empty))
            return .continue

        case UInt8(ascii: "D"):
            guard header.count == 1 else {
                throw IRRdOriginRouteClientError.protocolViolation(
                    "not-found response contained unexpected header data"
                )
            }
            context.fireChannelRead(wrapInboundOut(.notFound))
            return .continue

        case UInt8(ascii: "F"):
            guard header.count >= 2, header[1] == UInt8(ascii: " ") else {
                throw IRRdOriginRouteClientError.protocolViolation(
                    "server-failure response did not contain the required message separator"
                )
            }
            guard let message = String(validating: header.dropFirst(2), as: UTF8.self) else {
                throw IRRdOriginRouteClientError.protocolViolation(
                    "server-failure message was not valid UTF-8"
                )
            }
            throw IRRdOriginRouteClientError.serverFailure(message)

        default:
            throw IRRdOriginRouteClientError.protocolViolation(
                "unknown response status byte 0x\(String(status, radix: 16))"
            )
        }
    }

    private mutating func decodePayload(
        byteCount: Int,
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer
    ) throws -> DecodingState {
        // CHANGE: IRRd includes the payload's final LF in the announced byte count;
        // the separate `C\n` completion marker immediately follows those bytes.
        guard buffer.readableBytes >= byteCount else {
            return .needMoreData
        }
        guard buffer.readableBytes - byteCount >= 2 else {
            return .needMoreData
        }

        let payloadStart = buffer.readerIndex
        guard
            buffer.getInteger(
                at: payloadStart + byteCount - 1,
                as: UInt8.self
            ) == UInt8(ascii: "\n")
        else {
            throw IRRdOriginRouteClientError.protocolViolation(
                "successful response payload did not end with a line feed"
            )
        }
        guard
            buffer.getInteger(at: payloadStart + byteCount, as: UInt8.self) == UInt8(ascii: "C"),
            buffer.getInteger(at: payloadStart + byteCount + 1, as: UInt8.self) == UInt8(ascii: "\n")
        else {
            throw IRRdOriginRouteClientError.protocolViolation(
                "successful response was not followed by the C completion marker"
            )
        }

        let contentByteCount = byteCount - 1
        guard
            let content = buffer.getBytes(at: payloadStart, length: contentByteCount),
            let payload = String(validating: content, as: UTF8.self)
        else {
            throw IRRdOriginRouteClientError.protocolViolation(
                "successful response payload was not valid UTF-8"
            )
        }

        buffer.moveReaderIndex(forwardBy: byteCount + 2)
        state = .awaitingHeader
        context.fireChannelRead(
            wrapInboundOut(.success(payload: payload, announcedByteCount: byteCount))
        )
        return .continue
    }

    private func parseAnnouncedByteCount(_ bytes: ArraySlice<UInt8>) throws -> Int {
        guard !bytes.isEmpty else {
            throw IRRdOriginRouteClientError.protocolViolation(
                "successful response omitted its byte count"
            )
        }

        var value = 0
        for byte in bytes {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                throw IRRdOriginRouteClientError.protocolViolation(
                    "successful response contained a non-decimal byte count"
                )
            }

            let multiplied = value.multipliedReportingOverflow(by: 10)
            let added = multiplied.partialValue.addingReportingOverflow(
                Int(byte - UInt8(ascii: "0"))
            )
            guard !multiplied.overflow, !added.overflow else {
                throw IRRdOriginRouteClientError.protocolViolation(
                    "successful response byte count was too large to represent"
                )
            }
            value = added.partialValue
        }
        return value
    }

    private mutating func recordSuccessfulResponse(byteCount: Int) throws {
        let total = sessionResponseBytes.addingReportingOverflow(byteCount)
        guard !total.overflow, total.partialValue <= maximumSessionResponseBytes else {
            let reportedTotal = total.overflow ? Int.max : total.partialValue
            throw IRRdOriginRouteClientError.sessionResponseTooLarge(
                limit: maximumSessionResponseBytes,
                accumulated: reportedTotal
            )
        }
        sessionResponseBytes = total.partialValue
    }
}
