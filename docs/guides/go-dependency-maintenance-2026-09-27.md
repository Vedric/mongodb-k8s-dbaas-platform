# Go dependency maintenance — 27 September 2026

This bounded update replaces dependency PRs [#141](https://github.com/Vedric/mongodb-k8s-dbaas-platform/pull/141), [#142](https://github.com/Vedric/mongodb-k8s-dbaas-platform/pull/142) and [#143](https://github.com/Vedric/mongodb-k8s-dbaas-platform/pull/143). Their consumer updates overlap: applying either one alone would leave the other dependency behind. Qualification of their combined versions also identified newer security fixes, included below without application-source changes.

| Module | Final dependencies changed by this batch |
| --- | --- |
| `api/gateway` | `x/net v0.56.0`, `x/sys v0.46.0`, `x/term v0.44.0`, `x/text v0.39.0` |
| `cdc/consumer` | `x/net v0.57.0`, `x/crypto v0.56.0`, `x/sys v0.47.0`, `klauspost/compress v1.18.7` |

The gateway retains `go 1.25.0`; the consumer now requires `go 1.26.0` because [x/crypto v0.56.0](https://proxy.golang.org/golang.org/x/crypto/@v/v0.56.0.mod) raises its minimum and selects `x/net v0.57.0` plus its transitives. The old Go 1.22/1.23 Docker builders depended on automatic toolchain downloads. Both builders and the Go CI jobs now select Go 1.26.8 explicitly and set `GOTOOLCHAIN=local` where compiling, so an incompatible SDK fails instead of silently downloading another version.

## Reproducible toolchain

The private Linux qualification SDK was downloaded from [go.dev](https://go.dev/dl/go1.26.8.linux-amd64.tar.gz) and checked against the SHA-256 in the [official release metadata](https://go.dev/dl/?mode=json&include=all):

```text
d0f743b33e8d8945e6b1f432edd15785c70507121d6e2a723b21285eddf8b57b
```

The Docker builder uses the official multi-platform image:

```text
golang:1.26.8-alpine3.23@sha256:a8fa79c5bd40d880b52bd3b6d7669ecdcfd00e85facdd427d279efb5ddd79cb1
```

The manifest digest was resolved from the official Docker registry before editing the Dockerfiles. The runtime image, application image tags and deployment manifests are unchanged. The new workflow pins [actions/setup-go v7.0.0](https://github.com/actions/setup-go/releases/tag/v7.0.0) at `b7ad1dad31e06c5925ef5d2fc7ad053ef454303e` and the repository's existing checkout v5 release at `fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09`.

## Module qualification

The earlier Go check only ran `gofmt`; the MongoDB kind integration workflow does not compile either Go application. `.github/workflows/go.yaml` now builds, vets and runs race-enabled tests for both modules independently on pull requests and pushes to `main`/`develop`. It verifies downloaded modules, checks reachable vulnerabilities with pinned `govulncheck v1.8.0`, and requires unchanged committed module files.

Run the same checks from each module directory with Go 1.26.8:

```sh
export GOTOOLCHAIN=local GOTELEMETRY=off
export GOFLAGS='-mod=readonly -p=1' GOMAXPROCS=1
go mod download
go mod verify
CGO_ENABLED=0 go build -trimpath -o /tmp/module-under-test .
go vet ./...
go test -race -count=1 -timeout=60s ./...
go install golang.org/x/vuln/cmd/govulncheck@v1.8.0
"$(go env GOPATH)/bin/govulncheck" ./...
git diff --exit-code -- go.mod go.sum
```

The gateway tests exercise its real client-go HTTP serialization against an ephemeral loopback Kubernetes fixture: claim creation and options, read/list filtering, deletion, missing claims and rejected malformed input. They never load kubeconfig or contact a cluster. The consumer tests verify synthetic event counters, labels and timestamps, malformed-event rejection, and omission of document bodies from processing logs. They do not connect to Kafka. These controls qualify the changed dependency graph, not a complete end-to-end deployment or production readiness of the existing gateway prototype.

Local qualification on 27 September passed module verification, `CGO_ENABLED=0` compilation, `go vet` and race-enabled tests in both modules: two top-level tests per module, with two additional invalid-input subcases in the gateway. The new workflow also passed Actionlint and the repository's Yamllint configuration; all Go files passed `gofmt`.

Neither this qualification nor the new module workflow builds or runs the Docker images. The existing floating `distroless` runtime-image tag remains outside this dependency batch and is not security-certified by these checks. The tests do not cover the live Kafka group protocol or `ConsumeClaim`, and the gateway's documented missing production authentication/rate limiting remain unchanged.

## Vulnerability findings and correction

The initial combined PR versions (`net 0.55`, `crypto 0.52`, gateway `text 0.37`) passed the module tests but left [GO-2026-5970](https://pkg.go.dev/vuln/GO-2026-5970) reachable through the gateway's client-go HTTP2/IDNA path into Unicode normalization. The scanner also matched module versions affected by [GO-2026-5942](https://pkg.go.dev/vuln/GO-2026-5942) (DNS parsing), [GO-2026-5841](https://pkg.go.dev/vuln/GO-2026-5841) (compression), and SSH advisories [GO-2026-6303](https://pkg.go.dev/vuln/GO-2026-6303), [GO-2026-6354](https://pkg.go.dev/vuln/GO-2026-6354) and [GO-2026-6355](https://pkg.go.dev/vuln/GO-2026-6355), without finding those symbols reachable. The final versions above include the available fixes and required transitives.

After correction, official `govulncheck v1.8.0` found **no reachable vulnerability in either module**, using the Go vulnerability database last modified on 24 September 2026. Both normal-text invocations exited zero. JSON findings were inspected separately: JSON mode alone returns zero even when findings exist and is not a sufficient pass/fail control.

The gateway has no remaining module-level match in that scan. The consumer retains one module-level match, [GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932): the deprecated OpenPGP package in `x/crypto`, for which no fixed release exists. No OpenPGP package is imported by either application, and the scanner found no imported-package or reachable-symbol finding for it. This distinction is not a vulnerability suppression or a claim of zero risk. New database entries can change future results; image, OS and application-design security require separate qualification.

## Deployment boundary

No application source, cluster resources, ArgoCD application sources, deployed application image references or release tags change. ArgoCD tracks `main` for its declared GitOps/operator/replica-set/observability/tenant-claim paths; this update changes none of those paths. The existing release workflow runs only for `v*` tags. Opening the replacement pull request runs CI, including the existing ephemeral kind integration job; it does not publish an application image or deploy a managed environment.

Close the three original PRs as superseded only after the replacement passes its checks and is integrated. Any unrelated dependency or runtime-image vulnerabilities found during qualification remain separately actionable; this maintenance batch must not be described as a complete security certification.
