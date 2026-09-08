#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "verify-pr-source: $*" >&2
  exit 1
}

validate_sha() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || \
    die "${name} must be exactly 40 lowercase hexadecimal characters"
}

expected_sha="${EXPECTED_SOURCE_SHA:-}"
expected_tree="${EXPECTED_SOURCE_TREE:-}"
validate_sha EXPECTED_SOURCE_SHA "$expected_sha"
validate_sha EXPECTED_SOURCE_TREE "$expected_tree"

actual_sha="$(git rev-parse HEAD)"
actual_tree="$(git rev-parse 'HEAD^{tree}')"
[[ "$actual_sha" = "$expected_sha" ]] || die 'checked-out HEAD does not match source job output'
[[ "$actual_tree" = "$expected_tree" ]] || die 'checked-out tree does not match source job output'

git diff --quiet --ignore-submodules=none -- || die 'tracked worktree is not clean'
git diff --cached --quiet --ignore-submodules=none -- || die 'index is not clean'

printf 'source_sha=%s\nsource_tree=%s\n' "$actual_sha" "$actual_tree"
printf 'runner_image_os=%s\nrunner_image_version=%s\n' \
  "${ImageOS:-unknown}" "${ImageVersion:-unknown}"
uname -a
nproc
free -h
df -h "$GITHUB_WORKSPACE"
