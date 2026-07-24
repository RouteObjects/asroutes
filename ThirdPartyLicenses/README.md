# Third-party license bundle

These files are retained from the exact dependency revisions recorded in the
root `Package.resolved` for the `asroutes` 0.1.0 release:

- `SwiftArgumentParser-LICENSE.txt`: Swift Argument Parser 1.7.0
- `SwiftAtomics-LICENSE.txt`: Swift Atomics 1.3.1
- `swift-cidr-LICENSE.txt`: swift-cidr 0.4.0
- `SwiftCollections-LICENSE.txt`: Swift Collections 1.6.0
- `SwiftNIO-LICENSE.txt`: SwiftNIO 2.100.0
- `SwiftNIO-NOTICE.txt`: SwiftNIO 2.100.0
- `SwiftSystem-LICENSE.txt`: Swift System 1.7.4

The following files cover runtime or vendored-component material relevant to
binary distribution:

- `Swift-6.1-Runtime-LICENSE.txt`: the Apache License 2.0 with Runtime Library
  Exception used by the official Swift 6.1 toolchain. Its contents were
  verified against the `swift-6.1-RELEASE` license.
- `swift-extras-base64-LICENSE.txt`: the exact license at the revision cited by
  SwiftNIO for the Base64 implementation used by `NIOCore`.
- `uSHET-LICENSE.txt`: the exact license at the revision cited by SwiftNIO for
  `cpp_magic.h` in its `CNIOAtomics` source tree.
- `SwiftNIO-llhttp-LICENSE.txt`: the exact license shipped with SwiftNIO's
  vendored llhttp component. `asroutes` does not link the `NIOHTTP1` target,
  but the file is retained alongside the complete SwiftNIO notice.

Other Apache-licensed derivations named in `SwiftNIO-NOTICE.txt` are covered
by the local `SwiftNIO-LICENSE.txt`. SwiftNIO targets that are not dependencies
of `NIOCore` or `NIOPosix` are not linked into the `asroutes` executable.
