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

import ASRoutesCLI

@main
enum ASRoutesMain {
    static func main() async {
        // Delegate directly to the package-visible command while keeping command logic
        // in the regular ASRoutesCLI module that Xcode and SwiftPM tests can import.
        await ASRoutesCommand.main()
    }
}
