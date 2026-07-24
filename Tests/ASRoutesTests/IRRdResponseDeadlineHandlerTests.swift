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

@Suite("IRRd response deadline")
struct IRRdResponseDeadlineHandlerTests {
    @Test("the response clock starts when the command is written")
    func deadlineStartsWithOutboundCommand() async throws {
        let eventLoop = NIOAsyncTestingEventLoop()
        let handler = IRRdResponseDeadlineHandler(
            eventLoop: eventLoop,
            timeout: .seconds(1)
        )
        let channel = await NIOAsyncTestingChannel(handler: handler, loop: eventLoop)
        try await channel.connect(
            to: SocketAddress(ipAddress: "127.0.0.1", port: 43)
        ).get()

        try await handler.expectResponses(1)

        // CHANGE: Advancing beyond the configured duration before a command write models the
        // scheduling pause that previously closed a busy Linux ARM64 session before `!n` was sent.
        await eventLoop.advanceTime(by: .seconds(2))
        #expect(channel.isActive)

        let command = ByteBuffer(string: "!n asroutes\n")
        _ = try await channel.writeOutbound(command)
        #expect(try await channel.readOutbound(as: ByteBuffer.self) == command)

        await eventLoop.advanceTime(by: .milliseconds(999))
        #expect(channel.isActive)

        await eventLoop.advanceTime(by: .milliseconds(1))
        #expect(!channel.isActive)

        do {
            try await channel.throwIfErrorCaught()
            Issue.record("Expected the response deadline to fire")
        } catch let error as IRRdOriginRouteClientError {
            #expect(error == .timeout(operation: "response"))
        } catch {
            Issue.record("Expected a typed response timeout, received \(error)")
        }

        let leftovers = try await channel.finish(acceptAlreadyClosed: true)
        #expect(leftovers.isClean)
    }
}
