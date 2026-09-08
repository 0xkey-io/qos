#!/usr/bin/env bash
set -euo pipefail

readonly -a LOCK_FILES=(
  Cargo.lock
  src/init/Cargo.lock
  src/qos_enclave/Cargo.lock
  src/qos_system/Cargo.lock
  src/qos_aws/Cargo.lock
)
readonly -a LOCK_MANIFESTS=(
  Cargo.toml
  src/init/Cargo.toml
  src/qos_enclave/Cargo.toml
  src/qos_system/Cargo.toml
  src/qos_aws/Cargo.toml
)
readonly -a IMAGE_NAMES=(
  qos_enclave_egress
  qos_host_qemu
  qos_bridge_qemu
  qos_client
  signed_echo
)
readonly -a TEST_NAMES=(signed_echo_egress_get_url signed_echo_ingress)

die() {
  printf 'qemu-local-gate: phase=%s outcome=failure error=%s\n' \
    "${PHASE_NAME:-bootstrap}" "$*" >&2
  exit 1
}

phase_start() {
  PHASE_NAME="$1"
  PHASE_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  PHASE_STARTED_SECONDS="$(date +%s)"
  printf 'phase=%s event=started occurred_at=%s\n' "$PHASE_NAME" "$PHASE_STARTED_AT"
}

phase_success() {
  local finished_seconds
  finished_seconds="$(date +%s)"
  printf 'phase=%s outcome=success duration_seconds=%s\n' \
    "$PHASE_NAME" "$((finished_seconds - PHASE_STARTED_SECONDS))"
}

validate_sha() {
  [[ "${SOURCE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || \
    die 'SOURCE_SHA must be exactly 40 lowercase hexadecimal characters'
}

require_gate_dirs() {
  [[ -n "${SOURCE_DIR:-}" && -d "$SOURCE_DIR" && ! -L "$SOURCE_DIR" ]] || \
    die 'SOURCE_DIR must be a non-symlink directory'
  [[ -n "${CONTROLLER_DIR:-}" && -d "$CONTROLLER_DIR" && ! -L "$CONTROLLER_DIR" ]] || \
    die 'CONTROLLER_DIR must be a non-symlink directory'
  [[ -n "${STATE_DIR:-}" && -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || \
    die 'STATE_DIR must be a non-symlink directory'
}

verify_source_identity() {
  local source_sha source_tree workflow_sha workflow_tree
  source_sha="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
  source_tree="$(git -C "$SOURCE_DIR" rev-parse 'HEAD^{tree}')"
  workflow_sha="$(git -C "$CONTROLLER_DIR" rev-parse HEAD)"
  workflow_tree="$(git -C "$CONTROLLER_DIR" rev-parse 'HEAD^{tree}')"
  [[ "$source_sha" == "$SOURCE_SHA" ]] || \
    die "checked-out HEAD ${source_sha} does not match requested source SHA ${SOURCE_SHA}"
  git -C "$SOURCE_DIR" diff --quiet --ignore-submodules=none -- || \
    die 'tracked source worktree is not clean'
  git -C "$SOURCE_DIR" diff --cached --quiet --ignore-submodules=none -- || \
    die 'source index is not clean'
  printf 'workflow_sha=%s\nworkflow_tree=%s\nsource_sha=%s\nsource_tree=%s\n' \
    "$workflow_sha" "$workflow_tree" "$source_sha" "$source_tree"
}

observe_runner() {
  printf 'runner_image_os=%s\nrunner_image_version=%s\n' \
    "${ImageOS:-unknown}" "${ImageVersion:-unknown}"
  uname -a
  command -v nproc >/dev/null 2>&1 && nproc || printf 'nproc=unavailable\n'
  command -v free >/dev/null 2>&1 && free -h || printf 'free=unavailable\n'
  df -h "${GITHUB_WORKSPACE:-$SOURCE_DIR}"
  cargo --version
  rustc --version
}

preflight() {
  validate_sha
  require_gate_dirs
  phase_start preflight
  verify_source_identity
  observe_runner

  (
    cd "$SOURCE_DIR"
    sha256sum "${LOCK_FILES[@]}"
  ) | tee "$STATE_DIR/lock-sha256.before"
  local -a statuses=("${PIPESTATUS[@]}")
  [[ "${statuses[0]}" -eq 0 ]] || die "lock hashing failed with exit ${statuses[0]}"
  [[ "${statuses[1]}" -eq 0 ]] || die "lock evidence capture failed with exit ${statuses[1]}"

  local manifest
  for manifest in "${LOCK_MANIFESTS[@]}"; do
    if ! (cd "$SOURCE_DIR" && cargo metadata --locked \
      --manifest-path "$manifest" --format-version 1 >/dev/null); then
      die "locked metadata failed for ${manifest}"
    fi
    printf 'lock_metadata=%s outcome=success\n' "$manifest"
  done
  phase_success
}

verify_oci_layout() {
  local name="$1" layout="$SOURCE_DIR/out/$1"
  [[ -d "$layout" && ! -L "$layout" ]] || die "OCI layout is missing for ${name}"
  ruby -rjson -rdigest -e '
    layout, name = ARGV
    index_path = File.join(layout, "index.json")
    abort "qemu-local-gate: OCI index is missing for #{name}" unless File.file?(index_path)
    index = JSON.parse(File.read(index_path))
    manifests = index.fetch("manifests", [])
    candidates = manifests.select do |item|
      item["mediaType"] == "application/vnd.oci.image.manifest.v1+json" &&
        item.dig("platform", "os") == "linux" &&
        item.dig("platform", "architecture") == "amd64"
    end
    unless manifests.length == 1 && candidates.length == 1
      abort "qemu-local-gate: expected exactly one linux/amd64 manifest descriptor for #{name}"
    end
    descriptor = candidates.fetch(0)
    digest = descriptor.fetch("digest", "")
    abort "qemu-local-gate: invalid manifest digest for #{name}" unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)
    blob = File.join(layout, "blobs", "sha256", digest.delete_prefix("sha256:"))
    abort "qemu-local-gate: referenced manifest blob is missing for #{name}" unless File.file?(blob)
    actual = "sha256:#{Digest::SHA256.file(blob).hexdigest}"
    abort "qemu-local-gate: manifest blob digest mismatch for #{name}" unless actual == digest
    expected_size = descriptor.fetch("size", -1)
    abort "qemu-local-gate: manifest blob size mismatch for #{name}" unless File.size(blob) == expected_size
    puts "oci_name=#{name} oci_manifest_digest=#{digest} oci_manifest_size=#{expected_size}"
  ' "$layout" "$name"
  printf 'oci_name=%s oci_index_sha256=%s\n' "$name" \
    "$(sha256sum "$layout/index.json" | awk '{print $1}')"
}

load_oci_layout() {
  local name="$1" layout="$SOURCE_DIR/out/$1" ref="qos-local/$1:latest"
  local load_log tar_exit docker_exit tee_exit
  local -a statuses
  load_log="$(mktemp "$STATE_DIR/docker-load.${name}.XXXXXX")"
  set +e
  tar -C "$layout" -cf - . | docker load 2>&1 | tee "$load_log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  tar_exit="${statuses[0]}"
  docker_exit="${statuses[1]}"
  tee_exit="${statuses[2]}"
  [[ "$tar_exit" -eq 0 ]] || die "OCI archive failed for ${name} with exit ${tar_exit}"
  [[ "$docker_exit" -eq 0 ]] || die "Docker load failed for ${name} with exit ${docker_exit}"
  [[ "$tee_exit" -eq 0 ]] || die "Docker load evidence capture failed for ${name} with exit ${tee_exit}"

  local image_record delimiters image_id repo_tags repo_digests extra
  image_record="$(docker image inspect --format \
    '{{.Id}}|{{json .RepoTags}}|{{json .RepoDigests}}' "$ref")" || \
    die "loaded image is not inspectable: ${ref}"
  delimiters="${image_record//[!|]/}"
  [[ "${#delimiters}" -eq 2 ]] || die "loaded image record has unexpected fields: ${ref}"
  IFS='|' read -r image_id repo_tags repo_digests extra <<<"$image_record"
  [[ -n "$image_id" && -n "$repo_tags" && -z "${extra:-}" ]] || \
    die "loaded image record is incomplete: ${ref}"
  [[ "$repo_tags" == *"\"${ref}\""* ]] || die "loaded image is missing exact local tag: ${ref}"
  printf 'image_ref=%s image_id=%s repo_tags=%s repo_digests=%s\n' \
    "$ref" "$image_id" "$repo_tags" "${repo_digests:-null}"
}

build_load() {
  validate_sha
  require_gate_dirs
  phase_start build-load
  (
    cd "$SOURCE_DIR"
    make \
      out/qos_enclave_egress/index.json \
      out/qos_host_qemu/index.json \
      out/qos_bridge_qemu/index.json \
      out/qos_client/index.json \
      out/signed_echo/index.json
  )
  local name
  for name in "${IMAGE_NAMES[@]}"; do
    verify_oci_layout "$name"
    load_oci_layout "$name"
  done
  printf 'loaded_images=%s\n' "${#IMAGE_NAMES[@]}"
  phase_success
}

require_local_images() {
  local -a variables=(
    QOS_TEST_QEMU_ENCLAVE_IMAGE
    QOS_TEST_QEMU_HOST_IMAGE
    QOS_TEST_QEMU_BRIDGE_IMAGE
    QOS_TEST_QEMU_CLIENT_IMAGE
    QOS_TEST_QEMU_PIVOT_IMAGE
  )
  local -a refs=(
    qos-local/qos_enclave_egress:latest
    qos-local/qos_host_qemu:latest
    qos-local/qos_bridge_qemu:latest
    qos-local/qos_client:latest
    qos-local/signed_echo:latest
  )
  local index variable actual
  for index in 0 1 2 3 4; do
    variable="${variables[$index]}"
    actual="${!variable:-}"
    [[ "$actual" == "${refs[$index]}" ]] || \
      die "${variable} must equal ${refs[$index]}"
  done
}

run_tests() {
  validate_sha
  require_gate_dirs
  require_local_images
  phase_start qemu-tests
  local list_log run_log listed passed cargo_exit tee_exit
  local -a statuses
  list_log="$(mktemp "$STATE_DIR/qemu-list.XXXXXX")"
  run_log="$(mktemp "$STATE_DIR/qemu-run.XXXXXX")"

  set +e
  (
    cd "$SOURCE_DIR"
    cargo test --locked -p qos_test_harness --features qemu-ci \
      --test docker_host_qemu_nitro -- --list
  ) 2>&1 | tee "$list_log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  cargo_exit="${statuses[0]}"
  tee_exit="${statuses[1]}"
  [[ "$cargo_exit" -eq 0 ]] || die "QEMU test discovery failed with exit ${cargo_exit}"
  [[ "$tee_exit" -eq 0 ]] || die "evidence capture failed with exit ${tee_exit}"
  local expected_tests
  expected_tests="$(printf '%s\n' "${TEST_NAMES[@]}" | sort)"
  listed="$(awk '$2 == "test" { sub(/:$/, "", $1); print $1 }' "$list_log" | sort)"
  [[ "$listed" == "$expected_tests" ]] || \
    die 'expected exactly the two QEMU tests'

  set +e
  (
    cd "$SOURCE_DIR"
    cargo test --locked -p qos_test_harness --features qemu-ci \
      --test docker_host_qemu_nitro -- --nocapture --test-threads=1
  ) 2>&1 | tee "$run_log"
  statuses=("${PIPESTATUS[@]}")
  set -e
  cargo_exit="${statuses[0]}"
  tee_exit="${statuses[1]}"
  [[ "$cargo_exit" -eq 0 ]] || die "QEMU test command failed with exit ${cargo_exit}"
  [[ "$tee_exit" -eq 0 ]] || die "evidence capture failed with exit ${tee_exit}"
  passed="$(awk '$1 == "test" && $NF == "ok" { print $2 }' "$run_log" | sort)"
  [[ "$passed" == "$expected_tests" ]] || \
    die 'expected exactly two passing QEMU tests'
  printf 'listed_tests=2\npassed_tests=2\ngate_exit=0\n'
  phase_success
}

verify_final() {
  validate_sha
  require_gate_dirs
  phase_start verify-final
  [[ -f "$STATE_DIR/lock-sha256.before" ]] || die 'initial lock evidence is missing'
  verify_source_identity
  (cd "$SOURCE_DIR" && sha256sum -c "$STATE_DIR/lock-sha256.before")
  command -v free >/dev/null 2>&1 && free -h || printf 'free=unavailable\n'
  df -h "${GITHUB_WORKSPACE:-$SOURCE_DIR}"
  phase_success
}

observe_tool_image() {
  local image="$1" query="$2"
  local record
  if ! record="$(docker image inspect --format '{{.Id}}|{{json .RepoTags}}' "$image" 2>/dev/null)"; then
    printf 'tool_image=%s outcome=absent\n' "$image"
    return
  fi
  printf 'tool_image=%s identity=%s\n' "$image" "$record"
  docker run --rm --entrypoint /bin/sh "$image" -c "$query"
}

cleanup() {
  phase_start cleanup
  command -v docker >/dev/null 2>&1 || {
    printf 'docker=unavailable cleanup_targets=0\n'
    phase_success
    return
  }
  local name container_output volume_output inventory_exit containers=0 volumes=0 cleanup_failed=0
  if container_output="$(docker ps -a --format '{{.Names}}')"; then
    :
  else
    inventory_exit="$?"
    container_output=''
    printf 'cleanup_inventory=containers outcome=failure exit=%s\n' \
      "$inventory_exit" >&2
    cleanup_failed=1
  fi
  while IFS= read -r name; do
    [[ "$name" == qos-test-harness-* ]] || continue
    [[ "$name" =~ ^qos-test-harness-[A-Za-z0-9_.-]+$ ]] || \
      die "unsafe harness container name: ${name}"
    printf 'cleanup_container=%s\n' "$name"
    if ! docker rm -f -- "$name"; then
      printf 'cleanup_container=%s outcome=failure\n' "$name" >&2
      cleanup_failed=1
    fi
    containers="$((containers + 1))"
  done <<<"$container_output"
  if volume_output="$(docker volume ls --format '{{.Name}}')"; then
    :
  else
    inventory_exit="$?"
    volume_output=''
    printf 'cleanup_inventory=volumes outcome=failure exit=%s\n' \
      "$inventory_exit" >&2
    cleanup_failed=1
  fi
  while IFS= read -r name; do
    [[ "$name" == qos-test-harness-* ]] || continue
    [[ "$name" =~ ^qos-test-harness-[A-Za-z0-9_.-]+$ ]] || \
      die "unsafe harness volume name: ${name}"
    printf 'cleanup_volume=%s\n' "$name"
    if ! docker volume rm -- "$name"; then
      printf 'cleanup_volume=%s outcome=failure\n' "$name" >&2
      cleanup_failed=1
    fi
    volumes="$((volumes + 1))"
  done <<<"$volume_output"
  printf 'cleanup_containers=%s cleanup_volumes=%s\n' "$containers" "$volumes"
  if ! observe_tool_image qos-local/qos_test_harness_nitro_tools:latest \
    "rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\\n' | sort"; then
    printf 'tool_image=qos-local/qos_test_harness_nitro_tools:latest outcome=observation_failure\n' >&2
    cleanup_failed=1
  fi
  if ! observe_tool_image qos-local/qos_test_harness_egress_tools:latest \
    "dpkg-query -W -f='\${Package} \${Version}\\n' | sort"; then
    printf 'tool_image=qos-local/qos_test_harness_egress_tools:latest outcome=observation_failure\n' >&2
    cleanup_failed=1
  fi
  [[ "$cleanup_failed" -eq 0 ]] || die 'one or more cleanup operations failed'
  phase_success
}

case "${1:-}" in
  validate-sha) validate_sha ;;
  preflight) preflight ;;
  build-load) build_load ;;
  run-tests) run_tests ;;
  verify-final) verify_final ;;
  cleanup) cleanup ;;
  *) die 'usage: qemu-local-gate.sh {validate-sha|preflight|build-load|run-tests|verify-final|cleanup}' ;;
esac
