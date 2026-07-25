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
import NIOCore

/// Owns raw bootstrap channels until a connection has been transferred to its caller.
// Every mutation is protected by `lock`; Channel close operations are documented
// by SwiftNIO as thread-safe and are deliberately performed after releasing the lock.
final class PendingChannelRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var channels: [ObjectIdentifier: any Channel] = [:]

    func register(_ channel: any Channel) -> Bool {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            channel.close(promise: nil)
            return false
        }

        channels[ObjectIdentifier(channel)] = channel
        lock.unlock()
        return true
    }

    func cancelAndClose() {
        lock.lock()
        isCancelled = true
        let channelsToClose = Array(channels.values)
        channels.removeAll(keepingCapacity: false)
        lock.unlock()

        for channel in channelsToClose {
            channel.close(promise: nil)
        }
    }

    func releaseAll() {
        lock.lock()
        channels.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}
