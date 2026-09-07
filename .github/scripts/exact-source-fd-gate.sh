#!/usr/bin/env bash
set -euo pipefail

readonly TEST_NAME='nitro_cli_compat::tests::command_send_all_closes_descriptors'

die() {
  echo "exact-source-fd-gate: $*" >&2
  exit 1
}

validate_sha() {
  [[ "${SOURCE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || \
    die 'SOURCE_SHA must be exactly 40 lowercase hexadecimal characters'
}

run_gate() {
  validate_sha
  [[ -n "${SOURCE_DIR:-}" ]] || die 'SOURCE_DIR is required'
  [[ -n "${CONTROLLER_DIR:-}" ]] || die 'CONTROLLER_DIR is required'

  local source_sha source_tree workflow_sha workflow_tree
  source_sha="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
  source_tree="$(git -C "$SOURCE_DIR" rev-parse 'HEAD^{tree}')"
  workflow_sha="$(git -C "$CONTROLLER_DIR" rev-parse HEAD)"
  workflow_tree="$(git -C "$CONTROLLER_DIR" rev-parse 'HEAD^{tree}')"

  [[ "$source_sha" = "$SOURCE_SHA" ]] || \
    die "checked-out HEAD ${source_sha} does not match requested source SHA ${SOURCE_SHA}"

  printf 'workflow_sha=%s\n' "$workflow_sha"
  printf 'workflow_tree=%s\n' "$workflow_tree"
  printf 'source_sha=%s\n' "$source_sha"
  printf 'source_tree=%s\n' "$source_tree"
  cargo --version
  rustc --version

  local list_log run_log listed_count passed_count cargo_exit tee_exit
  local -a pipeline_status
  list_log="$(mktemp)"
  run_log="$(mktemp)"
  trap 'rm -f "$list_log" "$run_log"' RETURN

  set +e
  (
    cd "$SOURCE_DIR"
    cargo test --locked --manifest-path src/qos_enclave/Cargo.toml \
      "$TEST_NAME" -- --exact --list
  ) | tee "$list_log"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  cargo_exit="${pipeline_status[0]}"
  tee_exit="${pipeline_status[1]}"
  if [[ "$cargo_exit" -ne 0 ]]; then
    printf 'gate_exit=%s\n' "$cargo_exit"
    die "FD test discovery command failed with exit ${cargo_exit}"
  fi
  if [[ "$tee_exit" -ne 0 ]]; then
    printf 'gate_exit=%s\n' "$tee_exit"
    die "evidence capture failed with exit ${tee_exit}"
  fi

  listed_count="$(awk -v test_name="${TEST_NAME}:" \
    '$1 == test_name && $2 == "test" { count++ } END { print count + 0 }' "$list_log")"
  [[ "$listed_count" -eq 1 ]] || \
    die "expected exactly one listed FD test, found ${listed_count}"

  set +e
  (
    cd "$SOURCE_DIR"
    cargo test --locked --manifest-path src/qos_enclave/Cargo.toml \
      "$TEST_NAME" -- --exact --nocapture --test-threads=1
  ) 2>&1 | tee "$run_log"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  cargo_exit="${pipeline_status[0]}"
  tee_exit="${pipeline_status[1]}"

  if [[ "$cargo_exit" -ne 0 ]]; then
    printf 'gate_exit=%s\n' "$cargo_exit"
    die "FD test command failed with exit ${cargo_exit}"
  fi
  if [[ "$tee_exit" -ne 0 ]]; then
    printf 'gate_exit=%s\n' "$tee_exit"
    die "evidence capture failed with exit ${tee_exit}"
  fi

  passed_count="$(awk -v test_name="$TEST_NAME" \
    '$1 == "test" && $2 == test_name && $NF == "ok" { count++ } END { print count + 0 }' "$run_log")"
  [[ "$passed_count" -eq 1 ]] || \
    die "expected exactly one passing FD test, found ${passed_count}"

  printf 'listed_tests=%s\n' "$listed_count"
  printf 'passed_tests=%s\n' "$passed_count"
  printf 'gate_exit=0\n'
}

case "${1:-}" in
  validate-sha) validate_sha ;;
  run) run_gate ;;
  *) die 'usage: exact-source-fd-gate.sh {validate-sha|run}' ;;
esac
