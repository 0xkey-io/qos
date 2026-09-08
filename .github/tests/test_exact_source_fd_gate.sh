#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
entry="${repo_root}/.github/scripts/exact-source-fd-gate.sh"
test_sha="0123456789abcdef0123456789abcdef01234567"
test_tree="89abcdef0123456789abcdef0123456789abcdef"

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
  case "$output" in
    *"$expected"*) ;;
    *) fail "expected failure containing '$expected', got: $output" ;;
  esac
}

make_fakes() {
  fake_bin="$1"
  mkdir -p "$fake_bin"
  mkdir -p "$(dirname "$fake_bin")/source" "$(dirname "$fake_bin")/controller"
  cat >"${fake_bin}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"${FAKE_CALL_LOG}"
case "$*" in
  *"rev-parse HEAD^{tree}"*) printf '%s\n' "${FAKE_TREE}" ;;
  *"rev-parse HEAD"*) printf '%s\n' "${FAKE_HEAD}" ;;
  *) exit 64 ;;
esac
EOF
  cat >"${fake_bin}/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cargo %s\n' "$*" >>"${FAKE_CALL_LOG}"
if [[ "$*" == "--version" ]]; then
  echo 'cargo 1.94.0 (test fixture)'
elif [[ "$*" == *"--list"* ]]; then
  printf '%b\n' "${FAKE_LIST_OUTPUT:-}"
else
  printf '%b\n' "${FAKE_RUN_OUTPUT:-}"
  exit "${FAKE_RUN_EXIT:-0}"
fi
EOF
  cat >"${fake_bin}/rustc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rustc %s\n' "$*" >>"${FAKE_CALL_LOG}"
echo 'rustc 1.94.0 (test fixture)'
EOF
  chmod +x "${fake_bin}/git" "${fake_bin}/cargo" "${fake_bin}/rustc"
}

test_malformed_sha_is_rejected_before_tool_execution() {
  local tmp output
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fakes "${tmp}/bin"
  : >"${tmp}/calls"

  assert_fails 'exactly 40 lowercase hexadecimal' env \
    PATH="${tmp}/bin:${PATH}" FAKE_CALL_LOG="${tmp}/calls" SOURCE_SHA='abc; uname -a' \
    "$entry" validate-sha
  [[ ! -s "${tmp}/calls" ]] || fail 'malformed SHA reached a git/cargo boundary'
}

test_source_head_mismatch_is_rejected_before_cargo() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fakes "${tmp}/bin"
  : >"${tmp}/calls"

  assert_fails 'does not match requested source SHA' env \
    PATH="${tmp}/bin:${PATH}" FAKE_CALL_LOG="${tmp}/calls" \
    SOURCE_SHA="$test_sha" FAKE_HEAD="ffffffffffffffffffffffffffffffffffffffff" FAKE_TREE="$test_tree" \
    SOURCE_DIR="${tmp}/source" CONTROLLER_DIR="${tmp}/controller" \
    "$entry" run
  ! grep -q '^cargo ' "${tmp}/calls" || fail 'HEAD mismatch reached cargo boundary'
}

test_absent_exact_test_is_rejected() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fakes "${tmp}/bin"
  : >"${tmp}/calls"

  assert_fails 'expected exactly one listed FD test, found 0' env \
    PATH="${tmp}/bin:${PATH}" FAKE_CALL_LOG="${tmp}/calls" \
    SOURCE_SHA="$test_sha" FAKE_HEAD="$test_sha" FAKE_TREE="$test_tree" \
    SOURCE_DIR="${tmp}/source" CONTROLLER_DIR="${tmp}/controller" \
    FAKE_LIST_OUTPUT='0 tests, 0 benchmarks' \
    "$entry" run
}

test_zero_executed_tests_is_rejected() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fakes "${tmp}/bin"
  : >"${tmp}/calls"

  assert_fails 'expected exactly one passing FD test, found 0' env \
    PATH="${tmp}/bin:${PATH}" FAKE_CALL_LOG="${tmp}/calls" \
    SOURCE_SHA="$test_sha" FAKE_HEAD="$test_sha" FAKE_TREE="$test_tree" \
    SOURCE_DIR="${tmp}/source" CONTROLLER_DIR="${tmp}/controller" \
    FAKE_LIST_OUTPUT='nitro_cli_compat::tests::command_send_all_closes_descriptors: test' \
    FAKE_RUN_OUTPUT='test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 1 filtered out' \
    "$entry" run
}

test_cargo_failure_is_propagated() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fakes "${tmp}/bin"
  : >"${tmp}/calls"

  assert_fails 'FD test command failed with exit 17' env \
    PATH="${tmp}/bin:${PATH}" FAKE_CALL_LOG="${tmp}/calls" \
    SOURCE_SHA="$test_sha" FAKE_HEAD="$test_sha" FAKE_TREE="$test_tree" \
    SOURCE_DIR="${tmp}/source" CONTROLLER_DIR="${tmp}/controller" \
    FAKE_LIST_OUTPUT='nitro_cli_compat::tests::command_send_all_closes_descriptors: test' \
    FAKE_RUN_OUTPUT='test nitro_cli_compat::tests::command_send_all_closes_descriptors ... FAILED' \
    FAKE_RUN_EXIT=17 \
    "$entry" run
}

test_evidence_capture_failure_is_fail_closed() {
  local tmp output
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fakes "${tmp}/bin"
  : >"${tmp}/calls"
  cat >"${tmp}/bin/tee" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "${FAKE_TEE_COUNT}" ]]; then
  count="$(<"${FAKE_TEE_COUNT}")"
fi
count="$((count + 1))"
printf '%s\n' "$count" >"${FAKE_TEE_COUNT}"
/usr/bin/tee "$@"
if [[ "$count" -eq 2 ]]; then
  exit 23
fi
EOF
  chmod +x "${tmp}/bin/tee"

  if output="$(env \
    PATH="${tmp}/bin:${PATH}" FAKE_CALL_LOG="${tmp}/calls" FAKE_TEE_COUNT="${tmp}/tee-count" \
    SOURCE_SHA="$test_sha" FAKE_HEAD="$test_sha" FAKE_TREE="$test_tree" \
    SOURCE_DIR="${tmp}/source" CONTROLLER_DIR="${tmp}/controller" \
    FAKE_LIST_OUTPUT='nitro_cli_compat::tests::command_send_all_closes_descriptors: test' \
    FAKE_RUN_OUTPUT='test nitro_cli_compat::tests::command_send_all_closes_descriptors ... ok' \
    "$entry" run 2>&1)"; then
    fail 'evidence capture failure unexpectedly succeeded'
  fi
  [[ "$output" == *'evidence capture failed with exit 23'* ]] || \
    fail "tee failure was not reported: $output"
  [[ "$output" != *'gate_exit=0'* ]] || fail 'tee failure reported a successful gate'
}

test_success_records_provenance_and_uses_locked_exact_gate() {
  local tmp output
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fakes "${tmp}/bin"
  : >"${tmp}/calls"

  output="$(env \
    PATH="${tmp}/bin:${PATH}" FAKE_CALL_LOG="${tmp}/calls" \
    SOURCE_SHA="$test_sha" FAKE_HEAD="$test_sha" FAKE_TREE="$test_tree" \
    SOURCE_DIR="${tmp}/source" CONTROLLER_DIR="${tmp}/controller" \
    FAKE_LIST_OUTPUT='nitro_cli_compat::tests::command_send_all_closes_descriptors: test' \
    FAKE_RUN_OUTPUT='test nitro_cli_compat::tests::command_send_all_closes_descriptors ... ok' \
    "$entry" run)"

  [[ "$output" == *"source_sha=${test_sha}"* ]] || fail 'source SHA was not recorded'
  [[ "$output" == *"source_tree=${test_tree}"* ]] || fail 'source tree was not recorded'
  [[ "$output" == *"workflow_sha=${test_sha}"* ]] || fail 'workflow SHA was not recorded'
  [[ "$output" == *"workflow_tree=${test_tree}"* ]] || fail 'workflow tree was not recorded'
  [[ "$output" == *'gate_exit=0'* ]] || fail 'successful gate exit was not recorded'
  grep -q -- '--locked --manifest-path src/qos_enclave/Cargo.toml nitro_cli_compat::tests::command_send_all_closes_descriptors -- --exact --list' "${tmp}/calls" || fail 'list command was not locked and exact'
  grep -q -- '--locked --manifest-path src/qos_enclave/Cargo.toml nitro_cli_compat::tests::command_send_all_closes_descriptors -- --exact --nocapture --test-threads=1' "${tmp}/calls" || fail 'run command was not locked and exact'
}

test_malformed_sha_is_rejected_before_tool_execution
test_source_head_mismatch_is_rejected_before_cargo
test_absent_exact_test_is_rejected
test_zero_executed_tests_is_rejected
test_cargo_failure_is_propagated
test_evidence_capture_failure_is_fail_closed
test_success_records_provenance_and_uses_locked_exact_gate
echo '7 exact-source FD gate behavior tests passed'
