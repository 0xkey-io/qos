#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
entry="${repo_root}/.github/scripts/check-no-dev-feature-powerset.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_fails() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "command unexpectedly succeeded: $*"
  fi
  [[ "$output" == *"$expected"* ]] || fail "expected '$expected', got: $output"
}

make_repo() {
  local repo="$1" include_lock="${2:-yes}"
  mkdir -p "${repo}/src/qos_hex/src"
  cat >"${repo}/Cargo.toml" <<'EOF'
[workspace]
members = ["src/qos_hex"]
resolver = "2"
EOF
  cat >"${repo}/src/qos_hex/Cargo.toml" <<'EOF'
[package]
name = "qos_hex"
version = "0.14.1"
edition = "2024"

[dependencies]
serde = "1"

[dev-dependencies]
dev-only = "1"
EOF
  printf 'pub fn fixture() {}\n' >"${repo}/src/qos_hex/src/lib.rs"
  if [[ "$include_lock" == yes ]]; then
    cp "${tmp}/original.lock" "${repo}/Cargo.lock"
  fi
  git init -q "$repo"
  git -C "$repo" config user.name 'QoS CI test'
  git -C "$repo" config user.email 'qos-ci-test@example.invalid'
  git -C "$repo" add Cargo.toml src
  [[ "$include_lock" != yes ]] || git -C "$repo" add Cargo.lock
  git -C "$repo" commit -qm fixture
}

make_mock_cargo() {
  mkdir -p "${tmp}/bin"
  cat >"${tmp}/bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|cargo %s\n' "$PWD" "$*" >>"${MOCK_CARGO_LOG}"
if [[ "$1 $2" == "hack --remove-dev-deps" ]]; then
  [[ "$PWD" != "${ORIGINAL_REPO}" ]] || exit 71
  awk '/^\[dev-dependencies\]/{exit} {print}' src/qos_hex/Cargo.toml >src/qos_hex/Cargo.toml.tmp
  mv src/qos_hex/Cargo.toml.tmp src/qos_hex/Cargo.toml
elif [[ "$1 $2" == "generate-lockfile --offline" ]]; then
  ! grep -q '^\[dev-dependencies\]' src/qos_hex/Cargo.toml || exit 72
  if [[ "${MOCK_NEWER_CACHE:-0}" == 1 ]]; then
    cp "${NEWER_LOCK}" Cargo.lock
  else
    cp "${DERIVED_LOCK}" Cargo.lock
  fi
elif [[ "$*" == "metadata --offline --format-version 1" ]]; then
  ! grep -q '^\[dev-dependencies\]' src/qos_hex/Cargo.toml || exit 72
  cp "${DERIVED_LOCK}" Cargo.lock
  printf '{"packages":[],"resolve":{"nodes":[]}}\n'
elif [[ "$1 $2" == "hack check" ]]; then
  [[ "$*" == 'hack check --locked --offline --feature-powerset --no-dev-deps -p qos_hex' ]] || exit 73
  ! grep -q '^\[dev-dependencies\]' src/qos_hex/Cargo.toml || exit 74
  if [[ "${MOCK_MUTATE_ORIGINAL:-0}" == 1 ]]; then
    printf '# unexpected mutation\n' >>"${ORIGINAL_REPO}/Cargo.lock"
  fi
  exit "${MOCK_POWERSET_EXIT:-0}"
else
  exit 70
fi
EOF
  chmod +x "${tmp}/bin/cargo"
}

run_helper() {
  local repo="$1" derived="$2"
  (
    cd "$repo"
    env PATH="${tmp}/bin:${PATH}" RUNNER_TEMP="${tmp}/runner" \
      MOCK_CARGO_LOG="${tmp}/cargo.log" ORIGINAL_REPO="$repo" DERIVED_LOCK="$derived" \
      NEWER_LOCK="${tmp}/derived-upgrade.lock" MOCK_NEWER_CACHE="${MOCK_NEWER_CACHE:-0}" \
      MOCK_POWERSET_EXIT="${MOCK_POWERSET_EXIT:-0}" \
      MOCK_MUTATE_ORIGINAL="${MOCK_MUTATE_ORIGINAL:-0}" "$entry" qos_hex
  )
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "${tmp}/runner"
cat >"${tmp}/original.lock" <<'EOF'
version = 4

[[package]]
name = "dev-only"
version = "1.0.0"
source = "registry+https://example.invalid/index"
checksum = "dddd"

[[package]]
name = "qos_hex"
version = "0.14.1"

[[package]]
name = "serde"
version = "1.0.0"
source = "registry+https://example.invalid/index"
checksum = "aaaa"
EOF
cat >"${tmp}/derived-good.lock" <<'EOF'
version = 4

[[package]]
name = "qos_hex"
version = "0.14.1"

[[package]]
name = "serde"
version = "1.0.0"
source = "registry+https://example.invalid/index"
checksum = "aaaa"
EOF
cat >"${tmp}/derived-upgrade.lock" <<'EOF'
version = 4

[[package]]
name = "qos_hex"
version = "0.14.1"

[[package]]
name = "serde"
version = "2.0.0"
source = "registry+https://example.invalid/index"
checksum = "bbbb"
EOF
make_mock_cargo

make_repo "${tmp}/repo"
original_hash="$(shasum -a 256 "${tmp}/repo/Cargo.lock" | awk '{print $1}')"
: >"${tmp}/cargo.log"
MOCK_NEWER_CACHE=1
output="$(run_helper "${tmp}/repo" "${tmp}/derived-good.lock")"
unset MOCK_NEWER_CACHE
[[ "$output" == *'derived_lock_packages=2'* ]] || fail 'derived lock evidence missing'
mapfile -t calls <"${tmp}/cargo.log"
[[ "${#calls[@]}" -eq 3 ]] || fail "expected 3 cargo calls, got ${#calls[@]}"
[[ "${calls[0]}" == *'|cargo hack --remove-dev-deps --workspace' ]] || fail 'manifest transform was not first'
[[ "${calls[1]}" == *'|cargo metadata --offline --format-version 1' ]] || fail 'lock-preserving offline resolution was not second'
[[ "${calls[2]}" == *'|cargo hack check --locked --offline --feature-powerset --no-dev-deps -p qos_hex' ]] || fail 'locked powerset was not last'
[[ "${calls[0]%%|*}" != "${tmp}/repo" ]] || fail 'cargo ran in original repository'
[[ "$(shasum -a 256 "${tmp}/repo/Cargo.lock" | awk '{print $1}')" == "$original_hash" ]] || fail 'original lock changed'
git -C "${tmp}/repo" diff --quiet || fail 'original tracked tree changed'
! find "${tmp}/runner" -mindepth 1 -maxdepth 1 -name 'qos-no-dev.*' | grep -q . || fail 'temporary copy was not removed'

: >"${tmp}/cargo.log"
assert_fails 'derived lock introduced package outside original lock' \
  run_helper "${tmp}/repo" "${tmp}/derived-upgrade.lock"
[[ "$(wc -l <"${tmp}/cargo.log" | tr -d ' ')" -eq 2 ]] || fail 'rejected lock reached powerset check'

make_repo "${tmp}/missing-lock" no
: >"${tmp}/cargo.log"
assert_fails 'original Cargo.lock is required' run_helper "${tmp}/missing-lock" "${tmp}/derived-good.lock"
[[ ! -s "${tmp}/cargo.log" ]] || fail 'missing original lock reached cargo'

make_repo "${tmp}/failure-repo"
: >"${tmp}/cargo.log"
MOCK_POWERSET_EXIT=17
MOCK_MUTATE_ORIGINAL=1
set +e
failure_output="$(run_helper "${tmp}/failure-repo" "${tmp}/derived-good.lock" 2>&1)"
status=$?
set -e
unset MOCK_POWERSET_EXIT
unset MOCK_MUTATE_ORIGINAL
[[ "$status" -eq 17 ]] || fail "powerset failure exit changed from 17 to ${status}"
[[ "$failure_output" == *'original Cargo.lock changed during derived check'* ]] || \
  fail "failure path did not report original lock postcondition: ${failure_output}"
! find "${tmp}/runner" -mindepth 1 -maxdepth 1 -name 'qos-no-dev.*' | grep -q . || \
  fail 'failure path did not remove temporary copy'

echo '4 no-dev feature powerset behavior tests passed'
