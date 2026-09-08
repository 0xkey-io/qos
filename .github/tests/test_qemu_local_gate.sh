#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
entry="${repo_root}/.github/scripts/qemu-local-gate.sh"
test_sha='0123456789abcdef0123456789abcdef01234567'
test_tree='89abcdef0123456789abcdef0123456789abcdef'

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

make_fixture() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/source" "$tmp/controller" "$tmp/state"
  mkdir -p "$tmp/source/src"/{init,qos_enclave,qos_system,qos_aws}
  : >"$tmp/calls"
  for lock in Cargo.lock src/init/Cargo.lock src/qos_enclave/Cargo.lock src/qos_system/Cargo.lock src/qos_aws/Cargo.lock; do
    printf 'lock=%s\n' "$lock" >"$tmp/source/$lock"
  done

  cat >"$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"${FAKE_CALL_LOG}"
case "$*" in
  *"rev-parse HEAD^{tree}"*) printf '%s\n' "${FAKE_TREE}" ;;
  *"rev-parse HEAD"*) printf '%s\n' "${FAKE_HEAD}" ;;
  *"diff --quiet"*|*"diff --cached --quiet"*) exit 0 ;;
  *) exit 64 ;;
esac
EOF
  cat >"$tmp/bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cargo %s\n' "$*" >>"${FAKE_CALL_LOG}"
if [[ "$*" == '--version' ]]; then
  echo 'cargo 1.94.0 (fixture)'
elif [[ "$*" == metadata* ]]; then
  [[ "$*" == *"${FAKE_STALE_MANIFEST:-not-present}"* ]] && exit 101
  exit 0
elif [[ "$*" == *'-- --list' ]]; then
  printf '%b\n' "${FAKE_LIST_OUTPUT:-}"
else
  printf '%b\n' "${FAKE_RUN_OUTPUT:-}"
  exit "${FAKE_RUN_EXIT:-0}"
fi
EOF
  cat >"$tmp/bin/rustc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo 'rustc 1.94.0 (fixture)'
EOF
  cat >"$tmp/bin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'make %s\n' "$*" >>"${FAKE_CALL_LOG}"
EOF
  cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"${FAKE_CALL_LOG}"
case "$1 ${2:-}" in
  'image inspect')
    image="${@: -1}"
    printf 'sha256:%064d|["%s"]|[]\n' 1 "$image"
    ;;
  'ps -a')
    [[ "${FAKE_DOCKER_PS_EXIT:-0}" -eq 0 ]] || exit "${FAKE_DOCKER_PS_EXIT}"
    printf '%b\n' "${FAKE_CONTAINERS:-}"
    ;;
  'volume ls')
    [[ "${FAKE_DOCKER_VOLUME_LS_EXIT:-0}" -eq 0 ]] || exit "${FAKE_DOCKER_VOLUME_LS_EXIT}"
    printf '%b\n' "${FAKE_VOLUMES:-}"
    ;;
  'rm -f'|'volume rm') ;;
  'run --rm')
    [[ "${FAKE_DOCKER_RUN_EXIT:-0}" -eq 0 ]] || exit "${FAKE_DOCKER_RUN_EXIT}"
    echo 'fixture-package 1.0'
    ;;
  *)
    if [[ "$1" == load ]]; then
      cat >/dev/null
      echo 'Loaded image fixture'
    else
      exit 64
    fi
    ;;
esac
EOF
  chmod +x "$tmp/bin"/*
}

gate_env() {
  local tmp="$1"
  shift
  env PATH="$tmp/bin:$PATH" FAKE_CALL_LOG="$tmp/calls" \
    SOURCE_SHA="$test_sha" FAKE_HEAD="$test_sha" FAKE_TREE="$test_tree" \
    SOURCE_DIR="$tmp/source" CONTROLLER_DIR="$tmp/controller" \
    STATE_DIR="$tmp/state" GITHUB_WORKSPACE="$tmp" "$@"
}

make_layouts() {
  local source="$1" scenario="${2:-valid}"
  local name digest manifests
  for name in qos_enclave_egress qos_host_qemu qos_bridge_qemu qos_client signed_echo; do
    mkdir -p "$source/out/$name/blobs/sha256"
    printf '{}' >"$source/out/$name/blob"
    digest="$(sha256sum "$source/out/$name/blob" | awk '{print $1}')"
    cp "$source/out/$name/blob" "$source/out/$name/blobs/sha256/$digest"
    manifests="{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:$digest\",\"size\":2,\"platform\":{\"architecture\":\"amd64\",\"os\":\"linux\"}}"
    if [[ "$scenario" == multiple && "$name" == qos_enclave_egress ]]; then
      manifests="$manifests,$manifests"
    elif [[ "$scenario" == wrong-digest && "$name" == qos_enclave_egress ]]; then
      digest="$(printf '0%.0s' {1..64})"
      cp "$source/out/$name/blob" "$source/out/$name/blobs/sha256/$digest"
      manifests="{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:$digest\",\"size\":2,\"platform\":{\"architecture\":\"amd64\",\"os\":\"linux\"}}"
    fi
    printf '{"schemaVersion":2,"manifests":[%s]}\n' "$manifests" >"$source/out/$name/index.json"
  done
}

test_malformed_sha_is_rejected_before_any_tool() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  assert_fails 'exactly 40 lowercase hexadecimal' env \
    PATH="$tmp/bin:$PATH" FAKE_CALL_LOG="$tmp/calls" SOURCE_SHA='main;id' \
    "$entry" validate-sha
  [[ ! -s "$tmp/calls" ]] || fail 'malformed SHA reached an external tool'
}

test_preflight_rejects_wrong_head_before_cargo() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  assert_fails 'does not match requested source SHA' env \
    PATH="$tmp/bin:$PATH" FAKE_CALL_LOG="$tmp/calls" SOURCE_SHA="$test_sha" \
    FAKE_HEAD='ffffffffffffffffffffffffffffffffffffffff' FAKE_TREE="$test_tree" \
    SOURCE_DIR="$tmp/source" CONTROLLER_DIR="$tmp/controller" STATE_DIR="$tmp/state" \
    GITHUB_WORKSPACE="$tmp" "$entry" preflight
  ! grep -q '^cargo ' "$tmp/calls" || fail 'wrong source reached Cargo'
}

test_preflight_fails_closed_on_stale_lock() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  assert_fails 'locked metadata failed for src/init/Cargo.toml' gate_env "$tmp" \
    env FAKE_STALE_MANIFEST='src/init/Cargo.toml' "$entry" preflight
}

test_final_verification_rejects_lock_drift() {
  local tmp output
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  output="$(gate_env "$tmp" "$entry" preflight)"
  [[ "$(grep -c '^lock_metadata=.* outcome=success$' <<<"$output")" -eq 5 ]] || \
    fail 'preflight did not record five locked metadata checks'
  printf 'changed\n' >>"$tmp/source/src/init/Cargo.lock"
  assert_fails 'FAILED' gate_env "$tmp" "$entry" verify-final
}

test_oci_layout_requires_one_linux_amd64_descriptor() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  make_layouts "$tmp/source" multiple
  assert_fails 'expected exactly one linux/amd64 manifest descriptor' gate_env "$tmp" \
    "$entry" build-load
}

test_oci_layout_verifies_referenced_blob_digest() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  make_layouts "$tmp/source" wrong-digest
  assert_fails 'manifest blob digest mismatch' gate_env "$tmp" "$entry" build-load
}

test_remote_image_input_is_rejected_before_cargo() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  assert_fails 'must equal qos-local/qos_client:latest' gate_env "$tmp" env \
    QOS_TEST_QEMU_ENCLAVE_IMAGE='qos-local/qos_enclave_egress:latest' \
    QOS_TEST_QEMU_HOST_IMAGE='qos-local/qos_host_qemu:latest' \
    QOS_TEST_QEMU_BRIDGE_IMAGE='qos-local/qos_bridge_qemu:latest' \
    QOS_TEST_QEMU_CLIENT_IMAGE='ghcr.io/example/qos_client:latest' \
    QOS_TEST_QEMU_PIVOT_IMAGE='qos-local/signed_echo:latest' \
    "$entry" run-tests
  ! grep -q '^cargo ' "$tmp/calls" || fail 'remote image ref reached Cargo'
}

test_missing_or_extra_test_names_are_rejected() {
  local tmp common_env
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  common_env=(env QOS_TEST_QEMU_ENCLAVE_IMAGE='qos-local/qos_enclave_egress:latest'
    QOS_TEST_QEMU_HOST_IMAGE='qos-local/qos_host_qemu:latest'
    QOS_TEST_QEMU_BRIDGE_IMAGE='qos-local/qos_bridge_qemu:latest'
    QOS_TEST_QEMU_CLIENT_IMAGE='qos-local/qos_client:latest'
    QOS_TEST_QEMU_PIVOT_IMAGE='qos-local/signed_echo:latest')
  assert_fails 'expected exactly the two QEMU tests' gate_env "$tmp" \
    "${common_env[@]}" FAKE_LIST_OUTPUT='signed_echo_ingress: test' "$entry" run-tests
  assert_fails 'expected exactly the two QEMU tests' gate_env "$tmp" \
    "${common_env[@]}" FAKE_LIST_OUTPUT=$'signed_echo_ingress: test\nsigned_echo_egress_get_url: test\nunexpected: test' "$entry" run-tests
}

test_cargo_and_evidence_failures_are_distinct() {
  local tmp common_env
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  common_env=(env QOS_TEST_QEMU_ENCLAVE_IMAGE='qos-local/qos_enclave_egress:latest'
    QOS_TEST_QEMU_HOST_IMAGE='qos-local/qos_host_qemu:latest'
    QOS_TEST_QEMU_BRIDGE_IMAGE='qos-local/qos_bridge_qemu:latest'
    QOS_TEST_QEMU_CLIENT_IMAGE='qos-local/qos_client:latest'
    QOS_TEST_QEMU_PIVOT_IMAGE='qos-local/signed_echo:latest'
    FAKE_LIST_OUTPUT=$'signed_echo_egress_get_url: test\nsigned_echo_ingress: test')
  assert_fails 'QEMU test command failed with exit 17' gate_env "$tmp" \
    "${common_env[@]}" FAKE_RUN_EXIT=17 "$entry" run-tests

  cat >"$tmp/bin/tee" <<'EOF'
#!/usr/bin/env bash
/usr/bin/tee "$@"
exit 23
EOF
  chmod +x "$tmp/bin/tee"
  assert_fails 'evidence capture failed with exit 23' gate_env "$tmp" \
    "${common_env[@]}" "$entry" run-tests
}

test_success_builds_exact_targets_and_requires_two_passes() {
  local tmp output common_env
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  make_layouts "$tmp/source"
  output="$(gate_env "$tmp" "$entry" build-load)"
  [[ "$output" == *'loaded_images=5'* ]] || fail 'five loaded images were not recorded'
  grep -Fq 'make out/qos_enclave_egress/index.json out/qos_host_qemu/index.json out/qos_bridge_qemu/index.json out/qos_client/index.json out/signed_echo/index.json' "$tmp/calls" || fail 'exact serial Make targets were not used'

  common_env=(env QOS_TEST_QEMU_ENCLAVE_IMAGE='qos-local/qos_enclave_egress:latest'
    QOS_TEST_QEMU_HOST_IMAGE='qos-local/qos_host_qemu:latest'
    QOS_TEST_QEMU_BRIDGE_IMAGE='qos-local/qos_bridge_qemu:latest'
    QOS_TEST_QEMU_CLIENT_IMAGE='qos-local/qos_client:latest'
    QOS_TEST_QEMU_PIVOT_IMAGE='qos-local/signed_echo:latest'
    FAKE_LIST_OUTPUT=$'signed_echo_egress_get_url: test\nsigned_echo_ingress: test'
    FAKE_RUN_OUTPUT=$'test signed_echo_egress_get_url ... ok\ntest signed_echo_ingress ... ok')
  output="$(gate_env "$tmp" "${common_env[@]}" "$entry" run-tests)"
  [[ "$output" == *'listed_tests=2'* && "$output" == *'passed_tests=2'* && "$output" == *'gate_exit=0'* ]] || fail 'two-test success evidence was incomplete'
  grep -Fq 'cargo test --locked -p qos_test_harness --features qemu-ci --test docker_host_qemu_nitro -- --nocapture --test-threads=1' "$tmp/calls" || fail 'QEMU test command changed'
}

test_cleanup_removes_only_harness_prefixed_resources() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  gate_env "$tmp" env \
    FAKE_CONTAINERS=$'qos-test-harness-app-123\nunrelated-container' \
    FAKE_VOLUMES=$'qos-test-harness-volume-123\nunrelated-volume' \
    "$entry" cleanup >/dev/null
  grep -Fq 'docker rm -f -- qos-test-harness-app-123' "$tmp/calls" || fail 'owned container was not removed'
  grep -Fq 'docker volume rm -- qos-test-harness-volume-123' "$tmp/calls" || fail 'owned volume was not removed'
  ! grep -Eq 'docker (rm|volume rm).*unrelated' "$tmp/calls" || fail 'cleanup crossed its ownership boundary'
}

test_container_inventory_failure_continues_safe_cleanup_and_observation() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  assert_fails 'one or more cleanup operations failed' gate_env "$tmp" env \
    FAKE_DOCKER_PS_EXIT=31 \
    FAKE_VOLUMES='qos-test-harness-volume-123' \
    "$entry" cleanup
  grep -Fq 'docker volume rm -- qos-test-harness-volume-123' "$tmp/calls" || fail 'container inventory failure blocked volume cleanup'
  ! grep -q '^docker rm -f -- ' "$tmp/calls" || fail 'unknown container inventory produced deletion targets'
  [[ "$(grep -c '^docker image inspect ' "$tmp/calls")" -eq 2 ]] || fail 'container inventory failure blocked tool image identity observations'
  [[ "$(grep -c '^docker run --rm ' "$tmp/calls")" -eq 2 ]] || fail 'container inventory failure blocked tool package observations'
}

test_volume_inventory_failure_continues_safe_cleanup_and_observation() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  assert_fails 'one or more cleanup operations failed' gate_env "$tmp" env \
    FAKE_DOCKER_VOLUME_LS_EXIT=32 \
    FAKE_CONTAINERS='qos-test-harness-app-123' \
    "$entry" cleanup
  grep -Fq 'docker rm -f -- qos-test-harness-app-123' "$tmp/calls" || fail 'volume inventory failure blocked container cleanup'
  ! grep -q '^docker volume rm -- ' "$tmp/calls" || fail 'unknown volume inventory produced deletion targets'
  [[ "$(grep -c '^docker image inspect ' "$tmp/calls")" -eq 2 ]] || fail 'volume inventory failure blocked tool image identity observations'
  [[ "$(grep -c '^docker run --rm ' "$tmp/calls")" -eq 2 ]] || fail 'volume inventory failure blocked tool package observations'
}

test_cleanup_still_removes_resources_if_tool_observation_fails() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_fixture "$tmp"
  assert_fails 'one or more cleanup operations failed' gate_env "$tmp" env \
    FAKE_DOCKER_RUN_EXIT=29 \
    FAKE_CONTAINERS='qos-test-harness-app-123' \
    FAKE_VOLUMES='qos-test-harness-volume-123' \
    "$entry" cleanup
  grep -Fq 'docker rm -f -- qos-test-harness-app-123' "$tmp/calls" || fail 'observation failure blocked container cleanup'
  grep -Fq 'docker volume rm -- qos-test-harness-volume-123' "$tmp/calls" || fail 'observation failure blocked volume cleanup'
}

test_malformed_sha_is_rejected_before_any_tool
test_preflight_rejects_wrong_head_before_cargo
test_preflight_fails_closed_on_stale_lock
test_final_verification_rejects_lock_drift
test_oci_layout_requires_one_linux_amd64_descriptor
test_oci_layout_verifies_referenced_blob_digest
test_remote_image_input_is_rejected_before_cargo
test_missing_or_extra_test_names_are_rejected
test_cargo_and_evidence_failures_are_distinct
test_success_builds_exact_targets_and_requires_two_passes
test_cleanup_removes_only_harness_prefixed_resources
test_container_inventory_failure_continues_safe_cleanup_and_observation
test_volume_inventory_failure_continues_safe_cleanup_and_observation
test_cleanup_still_removes_resources_if_tool_observation_fails
echo '14 local QEMU gate behavior tests passed'
