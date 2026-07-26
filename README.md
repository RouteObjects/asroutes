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
- iOS 18 or newer when using the `ASRoutesClient` library in an application
- TCP access to an IRRd raw-Whois service (normally port 43)

The initial release is verified with `swift-cidr` 0.4.0, SwiftNIO 2.100.0, and
Swift Argument Parser 1.7.0. `Package.resolved` records the exact dependency
revisions used for release verification.

## Build from source

Clone the repository and build a release executable:

```sh
git clone https://github.com/RouteObjects/asroutes.git
cd asroutes
swift build -c release --product asroutes
.build/release/asroutes --version
```

Run the test suite with:

```sh
swift test
```

The SwiftPM executable product, source-built binary, and published command are
all named `asroutes`.

## Command-line usage

Pass one or more ASNs in canonical asplain form, either as bare decimal digits
or with an uppercase `AS` prefix:

```sh
swift run asroutes AS701
swift run asroutes 701 AS3356
```

IPv4 is the default. Use `-4` to select it explicitly or `-6` to retrieve IPv6
route objects instead:

```sh
swift run asroutes AS701       # IPv4 by default
swift run asroutes -4 AS701    # Explicit IPv4
swift run asroutes -6 AS701    # IPv6
```

`-4` and `-6` are mutually exclusive; each invocation retrieves exactly one
address family.

Noncanonical spellings such as `000701`, `AS000701`, `as701`, and `As701` are
rejected rather than silently normalized.

The defaults query `rr.ntt.net` on TCP port 43. The server's current source
selection is discovered and retained for the session. A different server,
port, or ordered source list can be selected explicitly:

```sh
swift run asroutes --host rr.ntt.net --port 43 --sources RADB,RIPE AS701
```

`--connect-timeout` and `--query-timeout` accept positive seconds when a
deployment needs values other than the 10-second connection and 30-second
response defaults.

### Output formats

By default, `asroutes` writes only prefixes, one per line, with no ASN headers
or blank separators. The flat stream removes exact duplicates across all
requested ASNs and sorts the result numerically by network bits and then prefix
length. Covered more-specifics remain present. `--raw` selects that format
explicitly:

```sh
asroutes --raw AS701 AS3356
```

The default output is therefore directly composable with tools that accept
CIDR prefixes on standard input:

```sh
asroutes AS701 AS3356 | cidrmerge
asroutes AS701 AS3356 | cidrmerge --representation cidr
```

The first pipeline produces `cidrmerge`'s default minimal address-range
representation. The second requests a minimal CIDR-prefix representation
instead. In both cases, `asroutes` supplies the same unadorned prefix stream. If
no requested ASN has a visible prefix, raw output is empty.

Use `--grouped` or `-g` when human-readable ASN attribution is useful:

```sh
asroutes --grouped AS701 AS64500
```

```text
AS701:
10.0.0.0/8
203.0.113.0/24

AS64500:
(no prefixes)
```

Use `--json` or `-j` for structured output that preserves the association
between each ASN and its prefixes:

```json
[
  {
    "asn" : 701,
    "prefixes" : [
      "10.0.0.0/8",
      "203.0.113.0/24"
    ]
  },
  {
    "asn" : 64500,
    "prefixes" : []
  }
]
```

The top-level value is an array in first-seen ASN order. Each `asn` is an
unsigned decimal number, and each `prefixes` value is an array of canonical
CIDR strings in deterministic order. An ASN with no visible prefixes remains in
the result with an empty array.

Prefixes can be extracted from JSON for another command with `jq`:

```sh
asroutes --json AS701 AS3356 | jq -r '.[].prefixes[]' | cidrmerge
```

`--raw`, `--grouped`, and `--json` are mutually exclusive output selections.
Grouped and JSON output preserve first-seen ASN order and keep prefixes
associated with their ASN, including a prefix appearing under more than one
ASN; raw output intentionally discards that attribution. In every format,
`asroutes` retains covered more-specifics and does not aggregate or summarize
the server's answer.

Duplicate ASN operands are queried once and retain their first-seen position.
An invalid operand, connection failure, timeout, malformed response, or invalid
prefix produces an error on standard error and a nonzero exit status. Output is
buffered until the entire query succeeds, so a failed request does not leave a
partial route snapshot on standard output.

## Library usage

Add the package and `ASRoutesClient` library product to another Swift package:

```swift
dependencies: [
    .package(
        url: "https://github.com/RouteObjects/asroutes.git",
        from: "0.1.0"
    ),
    .package(
        url: "https://github.com/RouteObjects/swift-cidr.git",
        .upToNextMinor(from: "0.4.0")
    ),
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: [
            .product(name: "ASRoutesClient", package: "asroutes"),
            .product(name: "CIDR", package: "swift-cidr"),
        ]
    ),
]
```

Applications that use the result model also use `swift-cidr` types directly,
so declare the `swift-cidr` package and its `CIDR` product explicitly as shown
instead of relying on a transitive dependency.

The `ASRoutesClient` product exposes the client independently of the executable:

```swift
import ASRoutesClient
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

The shared result model is `ASOriginIPRoutes<Family>`. It contains an
`AutonomousSystemNumber` and family-bound `[IPNetwork<Family>]` prefixes. The
ordinary family-specific names remain available as public aliases:

- `ASOriginIPv4Routes` is `ASOriginIPRoutes<V4>` and contains `IPv4Network`
  prefixes.
- `ASOriginIPv6Routes` is `ASOriginIPRoutes<V6>` and contains `IPv6Network`
  prefixes.

The IRRd client currently produces only these `V4` and `V6` specializations.
The aliases also provide their family context when constructing an empty result,
so `ASOriginIPv4Routes(asn: asn, prefixes: [])` needs no explicit generic argument.

Accordingly, `ipv4Routes(for:)` continues to return
`[ASOriginIPv4Routes]`, and `ipv6Routes(for:)` continues to return
`[ASOriginIPv6Routes]`. Both APIs preserve first-seen ASN order, remove exact
duplicate prefixes, retain covered more-specifics, and sort the remaining
prefixes deterministically.

The generic model also supports algorithms shared by both address families
without erasing their type information:

```swift
func isCovered<Family: IPAddressFamily>(
    _ address: IPAddress<Family>,
    by routes: ASOriginIPRoutes<Family>
) -> Bool {
    routes.prefixes.contains { $0.contains(address) }
}
```

The shared `Family` parameter requires the address and routes to use the same
IP family at compile time. An IPv4 address cannot be passed with IPv6 routes,
or vice versa.

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
same ordered sources. Because `asroutes` uses raw output by default, the
equivalent IPv4 direct-origin lookup is:

```sh
bgpq4 -h rr.ntt.net -S RADB,RIPE -4 -F '%n/%l\n' AS701
swift run asroutes -4 --host rr.ntt.net --sources RADB,RIPE AS701
```

For IPv6, use `-6` with both tools:

```sh
bgpq4 -h rr.ntt.net -S RADB,RIPE -6 -F '%n/%l\n' AS701
swift run asroutes -6 --host rr.ntt.net --sources RADB,RIPE AS701
```

The two prefix sets can be compared after applying the same deterministic sort.
Do not compare against a hard-coded count because the backing IRR databases are
mutable.

## Scope

This proof of concept supports direct-ASN IPv4 and IPv6 origin lookups, one
address family per invocation. Mixed-family output, AS-set expansion, prefix
aggregation, caching, policy generation, and RouteObjects UI integration remain
outside its scope.

## License

`asroutes` is available under the Apache License 2.0. See [LICENSE](LICENSE).
Resolved dependency and binary-runtime attribution information is recorded in
[THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).

## References

- [IRRd Whois query protocol](https://irrd.readthedocs.io/en/stable/users/queries/whois/)
- [bgpq4](https://github.com/bgp/bgpq4)
