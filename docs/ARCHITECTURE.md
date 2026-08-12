# Architecture & Approach

Reasoning behind `Dockerfile`, `k8s/`, and `.github/workflows/`, organized
around what the assignment says you'll be asked to explain.

## Deployment strategy

`RollingUpdate`, `maxUnavailable: 0` / `maxSurge: 1`: a new Pod must be
Ready before an old one is removed. Two details make that actually hold:

- **Readiness accounts for the app's real startup delay.** `main.go`
  sleeps 10s before opening its listening socket. `initialDelaySeconds`/
  `periodSeconds` on the readiness probe are set so kubelet never routes
  traffic to a Pod that isn't actually listening yet.
- **Termination isn't graceful in the app itself.** No `SIGTERM` handler,
  so the process dies instantly on signal - and endpoint removal from the
  Service races with `SIGTERM` delivery during a Pod delete, a common
  source of dropped requests in rollouts that only *look* zero-downtime.
  `lifecycle.preStop.sleep.seconds: 5` (Kubernetes' native sleep action -
  no shell needed, distroless has none) delays `SIGTERM` until the
  endpoint removal has propagated through kube-proxy.

Verified, not assumed: 373 consecutive `/health` requests through the
Service during a live `kubectl rollout restart` - **zero non-200
responses**. Two real bugs surfaced doing this; see "Bugs found" below.

## Scaling strategy

Not wired up (out of scope for a 2-3 hour take-home), but the path:
- **HPA** on CPU/memory - the app is stateless, no session affinity, no
  local state, trivially horizontal.
- The `PodDisruptionBudget` (`minAvailable: 1`) and node anti-affinity
  already in `k8s/` matter more as replica count grows - they're what
  stops a node drain or scale-down from taking out a chunk of capacity at
  once.
- On EKS: **Karpenter** over Cluster Autoscaler - faster bin-packing,
  better spot support, native ARM64/Graviton node selection (relevant
  since the image is multi-arch).

## Security measures

- **Distroless, non-root, no shell.** `gcr.io/distroless/static-debian12:nonroot`
  - 13.8MB, uid 65532. Verified: `docker exec ... /bin/sh` fails, "no such
  file or directory" - nothing to pop even with code execution.
- **Hardened `securityContext`**: `runAsNonRoot`, `readOnlyRootFilesystem`,
  `allowPrivilegeEscalation: false`, all capabilities dropped,
  `seccompProfile: RuntimeDefault`.
- **No secrets in the codebase.** The app reads its token from a *file*
  (`SECRET_FILE_PATH`), mounted from a Secret volume rather than an env
  var - never appears in the Pod spec or `kubectl describe`.
  `k8s/01-secret.example.yaml` is a placeholder template only.
- **Egress-locked via `NetworkPolicy`.** App calls nothing external, so
  default-deny egress except DNS is enforced, not incidental. Ingress is
  left unrestricted on purpose (some CNIs apply NetworkPolicy to kubelet
  probe traffic; locking egress alone already satisfies "no direct
  internet access").
  **Caveat**: Minikube's default `bridge` CNI doesn't enforce
  `NetworkPolicy` at all, so this was validated as *API-accepted and
  structurally correct*, not as *actually blocking traffic*. Real
  enforcement needs a policy-aware CNI (`--cni=calico` locally; on EKS,
  the VPC CNI needs its policy enforcement mode on, or Calico/Cilium
  layered in).
- **CI-gated vulnerability scanning** - see below, including what it
  actually caught.

## CI/CD pipeline

- **`ci.yml`**, every push/PR: `gofmt`, `go vet`, `go build`, `go test`,
  plus a non-blocking Trivy filesystem scan (SARIF to the Security tab).
  Fast, doesn't gate anything.
- **`release.yml`**, only on a `v*.*.*` tag: multi-arch build, push to
  GHCR, then a **blocking** Trivy image scan (`exit-code: 1` on
  CRITICAL/HIGH). `:latest` is promoted - a cheap server-side
  `buildx imagetools create` re-tag, no rebuild - only *after* the scan
  passes, so the tag most pull configs default to can never point at an
  unscanned or failing image.

This gate isn't theoretical - see "Bugs found" below for what it actually
caught during local verification.

## Multi-architecture builds

`setup-qemu-action` + `buildx` build `linux/amd64` and `linux/arm64` from
one Dockerfile into a single manifest-list tag. `--platform=$BUILDPLATFORM`
keeps the Go compiler on the runner's native arch and only cross-compiles
the output - emulating the whole build under QEMU would be far slower for
no benefit.

The Deployment *prefers* `arm64` via node affinity (not `required`) -
matches "ARM64 preferred" while still scheduling on amd64-only clusters.

## Versioning and tagging strategy

Semver git tags (`vX.Y.Z`) drive image tags 1:1 via `docker/metadata-action`:
`v1.2.3` → `1.2.3`, `1.2`, `1`. `latest` is reserved for stable
(non-prerelease) releases - a tag with a hyphen (`v1.2.3-rc1`) never gets
`latest`, and its GitHub Release is marked prerelease too. Binary releases
share the same tag and the same GitHub Release as the image.

## Managing older/stale versions

`cleanup.yml` runs weekly: keeps the 10 most recently tagged versions,
removes untagged ones (failed/superseded pushes). Uses
`dataaxiom/ghcr-cleanup-action` rather than the more common
`actions/delete-package-versions`, because the latter treats each
architecture's sub-manifest of a multi-arch image as an independent
"untagged" version and will delete it out from under a still-tagged
parent, breaking pulls for that platform. Manual runs default to dry-run;
the scheduled run deletes for real.

## Going to EKS

- **Compute**: managed node groups, or a Fargate profile - the app is
  small, stateless, no host-level requirements.
- **Ingress**: AWS Load Balancer Controller provisions an ALB from the
  same `Ingress` resource - only `ingressClassName`/annotations change.
- **Secrets**: External Secrets Operator backed by AWS Secrets Manager,
  same volume-mount shape the app already expects; the value is never a
  static cluster-resident Secret, and rotates centrally.
- **IAM**: IRSA instead of static credentials anywhere in-cluster.
- **Network policy**: EKS's default VPC CNI doesn't enforce
  `NetworkPolicy` on its own - needs its policy-enforcement mode on, or
  Calico/Cilium, for the egress-lock design here to mean anything.
- **Scaling**: Karpenter (see above).

## Fast image pulls for globally distributed teams (AWS)

With **Amazon ECR**: cross-region replication turns a cross-ocean pull
into a same-region one; **VPC endpoints for ECR** let in-VPC pulls skip
the NAT gateway (lower latency and cost). An ECR pull-through cache is the
middle ground if managing replication policies isn't wanted.

This repo publishes to **GHCR**, already CDN-backed globally - so for a
GHCR-only setup, the slow-global-pull problem is largely already solved
by not self-hosting the registry. The ECR answer applies once/if the
registry moves in-house or into AWS for compliance/data-residency reasons.

## Bugs found and fixed during verification

Verification wasn't a formality - it caught issues static review missed:

1. **12 HIGH stdlib CVEs, 0 CRITICAL** (Trivy image scan) on the initial
   `golang:1.24-alpine` build - all fixed in Go's 1.25/1.26 branches. Go
   backports security fixes only to the two newest major versions, and
   1.24 had aged out. This is exactly what `release.yml`'s scan gate is
   for: fixed by bumping the builder image to `golang:1.26-alpine`
   (`go.mod`'s `go 1.24` is a floor, not a pin) - re-scan came back clean.
2. **`InvalidImageName`**: the placeholder image ref used an uppercase
   `OWNER` segment. OCI image references must be lowercase; kubelet
   rejected the Pod outright. Fixed with a valid lowercase placeholder.
3. **`permission denied` reading the secret file, crash-looping the
   container**: `runAsUser: 65532` with no matching `fsGroup` left the
   mounted Secret root-owned. Fixed with `securityContext.fsGroup: 65532`
   at the Pod level plus loosening the Secret's `defaultMode` from `0400`
   to `0440` so the now-matching group can read it.

(1) was caught by `trivy image` locally; (2) and (3) by `kubectl apply`
against a live Minikube cluster and reading `kubectl get pods`/`logs` -
none of the three were visible from reading the YAML alone.

A fourth gap was closed on review, not by a failure: the Deployment had no
`imagePullSecrets`, fine against a public GHCR package but an
`ImagePullBackOff` against a private one (the GHCR default). Added
`imagePullSecrets: [{name: ghcr-pull-secret}]` - inert until a pull is
actually attempted, with instructions in the manifest for either creating
that secret or making the package public instead.
