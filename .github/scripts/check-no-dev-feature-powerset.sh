#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "check-no-dev-feature-powerset: $*" >&2
  exit 1
}

package="${1:-}"
[[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die 'package must use safe name characters'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(git rev-parse --show-toplevel)"
original_lock="${repo_root}/Cargo.lock"
[[ -f "$original_lock" && ! -L "$original_lock" ]] || die 'original Cargo.lock is required and must not be a symlink'
git -C "$repo_root" diff --quiet --ignore-submodules=none -- || die 'original tracked worktree must be clean'
git -C "$repo_root" diff --cached --quiet --ignore-submodules=none -- || die 'original index must be clean'
original_lock_hash="$(sha256sum "$original_lock" | awk '{print $1}')"

temp_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
[[ -d "$temp_parent" && ! -L "$temp_parent" ]] || die 'temporary parent must be a real directory'
temp_root="$(mktemp -d "${temp_parent}/qos-no-dev.XXXXXX")"
[[ "$temp_root" == "${temp_parent}/qos-no-dev."* ]] || die 'unexpected temporary directory path'
derived_root="${temp_root}/source"
mkdir "$derived_root"

cleanup() {
  local original_status=$?
  local postcondition_status=0 cleanup_status=0 current_lock_hash
  trap - EXIT

  if ! current_lock_hash="$(sha256sum "$original_lock" 2>/dev/null | awk '{print $1}')" || \
    [[ "$current_lock_hash" != "$original_lock_hash" ]]; then
    echo 'check-no-dev-feature-powerset: original Cargo.lock changed during derived check' >&2
    postcondition_status=1
  fi
  if ! git -C "$repo_root" diff --quiet --ignore-submodules=none --; then
    echo 'check-no-dev-feature-powerset: original tracked worktree changed during derived check' >&2
    postcondition_status=1
  fi
  if ! git -C "$repo_root" diff --cached --quiet --ignore-submodules=none --; then
    echo 'check-no-dev-feature-powerset: original index changed during derived check' >&2
    postcondition_status=1
  fi
  if ! rm -rf -- "$temp_root"; then
    echo "check-no-dev-feature-powerset: failed to remove temporary copy ${temp_root}" >&2
    cleanup_status=1
  fi
  if [[ "$original_status" -ne 0 ]]; then
    exit "$original_status"
  fi
  if [[ "$postcondition_status" -ne 0 ]]; then
    exit "$postcondition_status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

git -C "$repo_root" archive --format=tar HEAD | tar -xf - -C "$derived_root"
[[ -f "${derived_root}/Cargo.lock" ]] || die 'exact source archive did not contain Cargo.lock'
[[ "$(sha256sum "${derived_root}/Cargo.lock" | awk '{print $1}')" == "$original_lock_hash" ]] || \
  die 'archived Cargo.lock does not match original Cargo.lock'

(
  cd "$derived_root"
  cargo hack --remove-dev-deps --workspace
  # Preserve versions/checksums from the copied original lock while Cargo
  # minimally updates the complete workspace resolve after dev-dependency
  # removal. A fresh generate-lockfile can select newer cache entries.
  cargo metadata --offline --format-version 1 >/dev/null
  "${script_dir}/verify-derived-cargo-lock.rb" "$original_lock" Cargo.lock
  cargo hack check --locked --offline --feature-powerset --no-dev-deps -p "$package"
)
