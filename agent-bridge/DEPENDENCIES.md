# Private helper dependencies

`go.mod` and `go.sum` pin dependencies. `vendor/modules.txt` records the generated package closure. Native source validation and release packaging use `GOFLAGS=-mod=vendor`. Builds require no private module download credential or sibling checkout.

The protocol owner is `github.com/personastack/agent-gateway/pkg/externalagentprotocol` at `v1.0.4-0.20261010111436-c50cf9c4510d`. Go generated its vendor copy from that published module. No gateway server or API client package is included. Do not edit vendored protocol fields. Change and publish the producer first, update the module pin and checksums, then regenerate vendor.

Regenerate from this module with authenticated module access:

```sh
GOFLAGS=-mod=mod go mod vendor
```

Run the source gate with networking disabled in the approved remote tester:

```sh
GOFLAGS=-mod=vendor GOPROXY=off GOSUMDB=off go test -race -parallel 30 ./...
```

The closure contains five package owners. Generated upstream licenses and notices stay alongside their source.

| Module | Version | Included package | License evidence |
| --- | --- | --- | --- |
| github.com/google/uuid | v1.6.0 | github.com/google/uuid | vendor/github.com/google/uuid/LICENSE |
| github.com/gorilla/websocket | v1.5.0 | github.com/gorilla/websocket | vendor/github.com/gorilla/websocket/LICENSE |
| github.com/personastack/agent-gateway | v1.0.4-0.20261010111436-c50cf9c4510d | pkg/externalagentprotocol | PersonaStack-owned private producer. Published module contains no third-party license file. |
| golang.org/x/sys | v0.41.0 | golang.org/x/sys/unix | vendor/golang.org/x/sys/LICENSE |
| gopkg.in/yaml.v3 | v3.0.1 | gopkg.in/yaml.v3 | vendor/gopkg.in/yaml.v3/LICENSE and NOTICE |

Darwin CGO compilation and the actual CoreFoundation account-boundary fixture run in native CI. Linux in-process tests do not prove Keychain ACL behavior or installed runtime interoperability.
