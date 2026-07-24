# asroutes

`asroutes` is a Swift command-line client and reusable library for looking up
the IPv4 or IPv6 IRR route objects whose `origin` attribute names a particular
Autonomous System. It queries an IRRd server over a persistent SwiftNIO TCP
connection and returns canonical `swift-cidr` network values.

The result is an IRR-derived view of registered routing intent. It is not a
snapshot of routes currently visible in the global BGP table.

## Requirements

- Swift 6.1 or newer
- macOS 15 or newer, or Ubuntu 22.04 or newer, to run the command-line
  executable
- iOS 18 or newer when using the `ASRoutes` library in an application
- TCP access to an IRRd raw-Whois service (normally port 43)

The initial release is verified with `swift-cidr` 0.4.0, SwiftNIO 2.100.0, and
Swift Argument Parser 1.7.0. `Package.resolved` records the exact dependency
revisions used for release verification.

## Build from source

Clone the repository and build a release executable:

```sh
git clone https://github.com/RouteObjects/asroutes.git
cd asroutes
swift build -c release --product asroutes-cli
.build/release/asroutes-cli --version
```

Run the test suite with:

```sh
swift test
```

The SwiftPM executable product and its source-built binary are named
`asroutes-cli`. This distinct name avoids Xcode's case-only build-product
collision between `asroutes` and the `ASRoutes` library module on
case-insensitive filesystems. Published release archives, and the Homebrew
formula when available, install the public command as `asroutes`.

## Command-line usage

Pass one or more ASNs in canonical asplain form, either as bare decimal digits
or with an uppercase `AS` prefix:

```sh
swift run asroutes-cli AS701
swift run asroutes-cli 701 AS3356
```

IPv4 is the default. Use `-4` to select it explicitly or `-6` to retrieve IPv6
route objects instead:

```sh
swift run asroutes-cli AS701       # IPv4 by default
swift run asroutes-cli -4 AS701    # Explicit IPv4
swift run asroutes-cli -6 AS701    # IPv6
```

`-4` and `-6` are mutually exclusive; each invocation retrieves exactly one
address family.

Noncanonical spellings such as `000701`, `AS000701`, `as701`, and `As701` are
rejected rather than silently normalized.

The defaults query `rr.ntt.net` on TCP port 43. The server's current source
selection is discovered and retained for the session. A different server,
port, or ordered source list can be selected explicitly:

```sh
swift run asroutes-cli --host rr.ntt.net --port 43 --sources RADB,RIPE AS701
```

`--connect-timeout` and `--query-timeout` accept positive seconds when a
deployment needs values other than the 10-second connection and 30-second
response defaults.

Each ASN is printed as a separate group. Exact duplicate prefixes are removed
and the remaining prefixes are sorted deterministically. Covered
more-specifics are intentionally retained; this command does not aggregate or
summarize the server's answer.

```text
AS701:
10.0.0.0/8
203.0.113.0/24

AS64500:
(no prefixes)
```

Duplicate ASN operands are queried once and retain their first-seen position.
An invalid operand, connection failure, timeout, malformed response, or invalid
prefix produces an error on standard error and a nonzero exit status. Output is
buffered until the entire query succeeds, so a failed request does not leave a
partial route snapshot on standard output.

## Library usage

Add the package and `ASRoutes` library product to another Swift package:

```swift
dependencies: [
    .package(
        url: "https://github.com/RouteObjects/asroutes.git",
        from: "0.1.0"
    ),
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: [
            .product(name: "ASRoutes", package: "asroutes"),
        ]
    ),
]
```

The `ASRoutes` product exposes the client independently of the executable:

```swift
import ASRoutes
import CIDR

let configuration = IRRdClientConfiguration(
    host: "rr.ntt.net",
    port: 43,
    sources: ["RADB", "RIPE"]
)
let client = IRRdOriginRouteClient(configuration: configuration)
let ipv4Results = try await client.ipv4Routes(for: [
    AutonomousSystemNumber(701),
    AutonomousSystemNumber(3356),
])

for result in ipv4Results {
    print("AS\(result.asn.description):")
    for prefix in result.prefixes {
        print(prefix)
    }
}

let ipv6Results = try await client.ipv6Routes(for: [
    AutonomousSystemNumber(701),
    AutonomousSystemNumber(3356),
])
```

`ipv4Routes(for:)` returns `[ASOriginIPv4Routes]`, whose prefixes are
`IPv4Network` values. `ipv6Routes(for:)` returns `[ASOriginIPv6Routes]`, whose
prefixes are `IPv6Network` values. Both APIs preserve first-seen ASN order,
remove exact duplicate prefixes, retain covered more-specifics, and sort the
remaining prefixes deterministically.

`AutonomousSystemNumber` is the numeric identity used by the client, result
models, collections, and command-line parser. The command locally removes an
optional uppercase `AS` prefix before parsing with `swift-cidr`, then requires
the remaining decimal text to use its canonical spelling.

`IRRdClientConfiguration` also controls connection and per-response timeouts,
the maximum accepted individual response size, and the maximum cumulative
response size retained by one session. A timeout is reset only by a complete
decoded response; a stream of incomplete frame bytes cannot extend it.

## Protocol and data caveats

The IRRd raw-Whois protocol on port 43 is plaintext: queries and responses are
neither encrypted nor authenticated. Choose and operate the server accordingly.

IRR sources differ in authority, maintenance, scope, filtering, and freshness.
The selected source order can materially change an answer. The compact IRRd
`!gAS<asn>` and `!6AS<asn>` responses contain only prefixes, so this client
cannot attach per-prefix source provenance to the result. If an application
needs auditable provenance, it must use a richer query path and retain the
returned route-object metadata.

IRR contents change over time. Live output counts should therefore not be used
as fixed test expectations.

## Comparing with bgpq4

For a useful comparison, point both tools at the same IRRd host and select the
same ordered sources. The equivalent IPv4 direct-origin lookup is:

```sh
bgpq4 -h rr.ntt.net -S RADB,RIPE -4 -F '%n/%l\n' AS701
swift run asroutes-cli -4 --host rr.ntt.net --sources RADB,RIPE AS701
```

For IPv6, use `-6` with both tools:

```sh
bgpq4 -h rr.ntt.net -S RADB,RIPE -6 -F '%n/%l\n' AS701
swift run asroutes-cli -6 --host rr.ntt.net --sources RADB,RIPE AS701
```

The two prefix sets can be compared after applying the same deterministic sort.
Do not compare against a hard-coded count because the backing IRR databases are
mutable.

## Scope

This proof of concept supports direct-ASN IPv4 and IPv6 origin lookups, one
address family per invocation. Mixed-family output, AS-set expansion, prefix
aggregation, JSON output, caching, policy generation, and RouteObjects UI
integration remain outside its scope.

## License

`asroutes` is available under the Apache License 2.0. See [LICENSE](LICENSE).
Resolved dependency and binary-runtime attribution information is recorded in
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).

## References

- [IRRd Whois query protocol](https://irrd.readthedocs.io/en/stable/users/queries/whois/)
- [bgpq4](https://github.com/bgp/bgpq4)
