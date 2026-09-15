# qos_client v0.2 Operator Release Design

## Context

0xkey-v2026.09.0 requires every KeyOps operator to use a `qos_client` built
from the same reviewed QoS revision as the Enclave release. QoS main
`8a157122a1cad4d5b0674bcda53ae0450d187fbc` contains the reconciled 0.14
security baseline, but main has no workflow that can build and publish the
required Linux AMD64 and Darwin ARM64 operator clients. The historical
`0xkey-qos_client-v0.1.0` tag contains a prototype workflow; it is evidence for
the artifact shape, not a safe implementation to restore unchanged.

This design adds the release mechanism. It does not create a tag, publish a
Release, build an Enclave manifest, handle quorum material, or deploy an
environment.

## Decision

Add one workflow, `.github/workflows/0xkey-qos-client-release.yml`, with two
explicit modes:

1. A pull request that changes the workflow or its contract tests builds and
   validates both operator clients with read-only permissions, then uploads
   short-lived workflow artifacts. It cannot publish a GitHub Release or
   attestation.
2. A matching tag push or an explicitly dispatched existing tag builds the
   same matrix, then a separately permissioned job publishes an immutable
   GitHub Release and build-provenance attestations.

The first intended release identifier is
`0xkey-qos_client-v0.2.0`. Creating that tag and executing the release mode are
separate, later-authorized operations.

## Alternatives

### Restore the historical workflow unchanged

Rejected. It uses floating Action references, permits asset replacement with
`--clobber`, writes checksum files that do not contain filenames, and does not
exercise the required YubiKey command surface before publication.

### Split build and publish into reusable workflows

Deferred. It creates another public interface and more cross-file policy for a
single current consumer. The release flow can be split later if a second
caller needs it.

### One dual-mode workflow

Selected. It keeps the source-selection and artifact contract in one review
unit while isolating all write authority in the final release-only job.

## Event and source state machine

The workflow accepts only these states:

| Event | Source revision | Build | Publish |
|---|---|---:|---:|
| `pull_request` | exact GitHub pull-request merge-ref SHA (`github.sha`) | Linux + Darwin | never |
| tag push matching `0xkey-qos_client-v[0-9]+.[0-9]+.[0-9]+` | exact pushed tag commit | Linux + Darwin | yes |
| `workflow_dispatch` with a matching existing tag | exact tag commit | Linux + Darwin | yes |

All other event/ref combinations fail closed before checkout. PR mode tests the
candidate as merged with its current base rather than silently substituting the
branch head. A dispatch input
must be the complete tag name, must match the stable semantic-version shape,
and must already resolve to a commit. Prerelease suffixes are not accepted by
this production workflow.

For release mode, the source commit must be reachable from `origin/main`. The
workflow records both commit and tree identity. Build jobs independently check
that their checkout matches the prepared identity. The publish job repeats the
identity check before consuming artifacts.

## Permission boundary

Workflow-level permissions are `contents: read`. The prepare, Linux, Darwin,
and PR-summary jobs remain read-only. Only the release-only publish job receives:

- `contents: write` to create the GitHub Release;
- `attestations: write` to publish provenance;
- `id-token: write` for the attestation identity.

No job receives package, ECR, AWS, environment, Kubernetes, manifest, quorum,
or member-secret authority. Checkout does not persist credentials in build
jobs. Every external Action is pinned to a full 40-character commit SHA.

Publishing refuses to continue if the release tag already exists as a GitHub
Release. Assets are never updated or replaced. A failed publication is retried
only after a human establishes whether the partial Release must be retained or
removed; the workflow does not make that destructive decision.

## Linux AMD64 build

The Linux job runs on `ubuntu-24.04` and builds only
`out/qos_client/index.json` through the reviewed StageX/Buildx path. It loads
that OCI layout, extracts `/qos_client`, and verifies:

- the file is executable and identified as an x86-64 Linux executable;
- the binary responds successfully to `--help`;
- help for `provision-yubikey`, `approve-manifest`,
  `proxy-re-encrypt-share`, and `after-genesis` succeeds;
- its SHA-256 is written as
  `<64 lowercase hex><two spaces>qos_client.linux-amd64`.

The job emits the binary, checksum, and a JSON metadata record containing the
source commit/tree, platform, build method, size, and SHA-256.

## Darwin ARM64 build

The Darwin job runs on the fixed `macos-14` runner, installs the repository's
Rust `1.94` toolchain and `aarch64-apple-darwin` target, and executes:

```bash
cargo build --release --locked --features smartcard \
  --target aarch64-apple-darwin -p qos_client
```

It sets `SOURCE_DATE_EPOCH=1`, `MACOSX_DEPLOYMENT_TARGET=11.0`, disables Cargo
color, and strips release symbols. It verifies an executable ARM64 Mach-O,
runs the same five help checks as Linux, and writes a standard filename-bearing
checksum. Metadata additionally records the exact `rustc` version and macOS
deployment target.

Darwin output is reproducible only within the recorded runner/toolchain
boundary; the workflow does not claim cross-runner byte reproducibility.

## Artifact and manifest contract

Both build jobs upload seven-day intermediate artifacts. The publish job
downloads only the two expected artifact names and rejects missing or extra
contract files.

`MANIFEST.json` uses schema `0xkey.qos-client-release/v1` and contains:

- release tag, repository, source commit, source tree, and workflow URL;
- generation timestamp;
- one closed record for `linux-amd64` and one for `darwin-arm64`;
- per platform: filename, checksum filename, size, SHA-256, build method, and
  toolchain/runtime facts needed to interpret reproducibility;
- the required YubiKey command list and a statement that all help checks passed.

Before publication, the publish job checks both checksum files, compares every
metadata revision and hash to the manifest, and validates the manifest's closed
schema. It attests the two binaries, their checksum files, and `MANIFEST.json`.

The GitHub Release contains exactly:

- `qos_client.linux-amd64`
- `qos_client.linux-amd64.sha256`
- `qos_client.darwin-arm64`
- `qos_client.darwin-arm64.sha256`
- `MANIFEST.json`

## Tests and pull-request gate

Ruby contract tests parse the workflow and assert:

- the accepted events and strict stable tag pattern;
- PR mode cannot reach the publish job;
- exact source identity is propagated to every build and publish step;
- build jobs are read-only and checkout does not persist credentials;
- only the publish job has the three required write permissions;
- all Actions use full commit SHAs;
- Linux uses StageX and Darwin uses the locked smartcard command;
- both jobs execute the required YubiKey help checks;
- checksum lines contain filenames;
- existing Releases are rejected and no clobber/update command exists;
- manifest schema and the exact five-file release allowlist are present.

Shell tests exercise source/tag validation and manifest assembly against local
fixtures. They cover malformed tags, prerelease tags, missing tags, non-main
commits, mismatched platform revisions, malformed checksums, extra files, and a
valid two-platform bundle.

The repository's existing PR `quality` aggregate must include these contract
tests. A workflow-only pull request therefore proves the non-publishing control
plane locally and builds both real platform binaries remotely before merge.

## Observability and failure handling

Every phase emits a stable `phase`, `source_commit`, `source_tree`, `platform`,
and outcome without printing credentials or sensitive inputs. The publish job
records the final Release URL and attestation verification command in the job
summary.

Build, checksum, schema, source identity, YubiKey-surface, or attestation
failure terminates the workflow. Publication never falls back to unattested
assets, never substitutes a different revision, and never overwrites an
existing release.

## Acceptance boundary

The implementation is ready to merge when its contract tests, existing QoS PR
checks, and both real platform build jobs pass for one fixed pull-request head.
Merge does not authorize `0xkey-qos_client-v0.2.0` creation or publication.

A later release checkpoint must fix the QoS main commit and tree, create the
exact tag, observe a successful release run, download all five assets, verify
both checksums and attestations, and record the release manifest hash before
the Builder may reference it in `builder-handoff.json`.
