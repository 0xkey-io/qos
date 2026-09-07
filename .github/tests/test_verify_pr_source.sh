#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
entry="${repo_root}/.github/scripts/verify-pr-source.sh"

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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git init -q "${tmp}/repo"
git -C "${tmp}/repo" config user.name 'QoS CI test'
git -C "${tmp}/repo" config user.email 'qos-ci-test@example.invalid'
printf 'clean\n' >"${tmp}/repo/tracked"
git -C "${tmp}/repo" add tracked
git -C "${tmp}/repo" commit -qm root
sha="$(git -C "${tmp}/repo" rev-parse HEAD)"
tree="$(git -C "${tmp}/repo" rev-parse 'HEAD^{tree}')"
mkdir "${tmp}/bin"
printf '#!/usr/bin/env bash\necho 4\n' >"${tmp}/bin/nproc"
printf '#!/usr/bin/env bash\necho fixture-memory\n' >"${tmp}/bin/free"
chmod +x "${tmp}/bin/nproc" "${tmp}/bin/free"

run_verify() {
  (
    cd "${tmp}/repo"
    env PATH="${tmp}/bin:${PATH}" GITHUB_WORKSPACE="${tmp}/repo" \
      EXPECTED_SOURCE_SHA="$sha" EXPECTED_SOURCE_TREE="$tree" "$entry"
  )
}

output="$(run_verify)"
[[ "$output" == *"source_sha=${sha}"* ]] || fail 'clean source did not report SHA'
[[ "$output" == *"source_tree=${tree}"* ]] || fail 'clean source did not report tree'

expected_tree="$tree"
tree="ffffffffffffffffffffffffffffffffffffffff"
assert_fails 'checked-out tree does not match source job output' run_verify
tree="$expected_tree"

printf 'dirty\n' >>"${tmp}/repo/tracked"
assert_fails 'tracked worktree is not clean' run_verify
git -C "${tmp}/repo" restore tracked
printf 'staged\n' >>"${tmp}/repo/tracked"
git -C "${tmp}/repo" add tracked
assert_fails 'index is not clean' run_verify
git -C "${tmp}/repo" restore --staged --worktree tracked

sha="ffffffffffffffffffffffffffffffffffffffff"
assert_fails 'checked-out HEAD does not match source job output' run_verify
echo '5 product source verification behaviors passed'
