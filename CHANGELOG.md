# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-24

### Added

- A reusable SwiftNIO client for direct-ASN IPv4 and IPv6 IRRd origin-route
  lookups.
- A command-line interface with explicit address-family, server, source, and
  timeout selection.
- Typed `swift-cidr` ASN and network results with deterministic sorting,
  exact deduplication, and retained more-specific prefixes.
- Pipelined multi-ASN sessions, protocol framing validation, response limits,
  cancellation handling, and atomic command output.
- macOS and Linux release packaging plus Swift Package Index documentation for
  the `ASRoutes` library.

[Unreleased]: https://github.com/RouteObjects/asroutes/compare/0.1.0...HEAD
[0.1.0]: https://github.com/RouteObjects/asroutes/releases/tag/0.1.0
