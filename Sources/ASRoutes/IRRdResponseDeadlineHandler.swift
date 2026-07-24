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

/// Enforces a deadline between complete decoded IRRd responses.
// CHANGE: This handler is mutated only on its channel's event loop. The unchecked
// conformance permits the async caller to ask that event loop to arm a deadline.
final class IRRdResponseDeadlineHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = IRRdResponse

    private let eventLoop: any EventLoop
    private let timeout: TimeAmount
    private var context: ChannelHandlerContext?
    private var remainingResponses = 0
    private var timeoutTask: Scheduled<Void>?

    init(eventLoop: any EventLoop, timeout: TimeAmount) {
        self.eventLoop = eventLoop
        self.timeout = timeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        eventLoop.preconditionInEventLoop()
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        eventLoop.preconditionInEventLoop()
        cancelDeadline()
        self.context = nil
    }

    func channelInactive(context: ChannelHandlerContext) {
        eventLoop.preconditionInEventLoop()
        cancelDeadline()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        eventLoop.preconditionInEventLoop()

        guard remainingResponses > 0 else {
            context.fireErrorCaught(
                IRRdOriginRouteClientError.protocolViolation(
                    "received an IRRd response when none was expected"
                )
            )
            context.close(promise: nil)
            return
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        remainingResponses -= 1

        // CHANGE: Only a complete A/C/D frame resets the response clock. Fragmented
        // bytes cannot keep a query alive indefinitely.
        if remainingResponses > 0 {
            scheduleDeadline()
        }

        context.fireChannelRead(data)
    }

    func expectResponses(_ count: Int) async throws {
        try Task.checkCancellation()

        try await eventLoop.submit {
            guard count > 0 else {
                throw IRRdOriginRouteClientError.protocolViolation(
                    "attempted to arm a response deadline with no expected responses"
                )
            }
            guard self.remainingResponses == 0, self.timeoutTask == nil else {
                throw IRRdOriginRouteClientError.protocolViolation(
                    "attempted to replace an active IRRd response deadline"
                )
            }
            guard self.context != nil else {
                throw IRRdOriginRouteClientError.transportFailure(
                    "response deadline handler was not attached to the channel"
                )
            }

            self.remainingResponses = count
            self.scheduleDeadline()
        }.get()

        try Task.checkCancellation()
    }

    private func scheduleDeadline() {
        eventLoop.preconditionInEventLoop()
        timeoutTask = eventLoop.scheduleTask(in: timeout) {
            self.timeoutTask = nil
            self.remainingResponses = 0
            guard let context = self.context else { return }
            context.fireErrorCaught(IRRdOriginRouteClientError.timeout(operation: "response"))
            context.close(promise: nil)
        }
    }

    private func cancelDeadline() {
        eventLoop.preconditionInEventLoop()
        timeoutTask?.cancel()
        timeoutTask = nil
        remainingResponses = 0
    }
}
