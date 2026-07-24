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

extension Duration {
    var nioTimeAmount: TimeAmount? {
        guard self > .zero else { return nil }

        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !seconds.overflow else { return nil }

        let fractionalNanoseconds = components.attoseconds / 1_000_000_000
        let total = seconds.partialValue.addingReportingOverflow(fractionalNanoseconds)
        guard !total.overflow, total.partialValue > 0 else { return nil }

        return .nanoseconds(total.partialValue)
    }
}
