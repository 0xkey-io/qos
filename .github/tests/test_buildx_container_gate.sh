#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
entry="${repo_root}/.github/scripts/verify-buildx-container.sh"

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
mkdir "${tmp}/bin"
cat >"${tmp}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"${MOCK_DOCKER_LOG}"
if [[ "$1 $2" == "buildx inspect" ]]; then
  case "${MOCK_SCENARIO}" in
    zero-node) exit 0 ;;
    multi-node)
      printf 'qos-123-1\tqos-validation\trunning\nqos-123-1-other\tqos-validation\trunning\n'
      ;;
    wrong-endpoint) printf 'qos-123-1\tdefault\trunning\n' ;;
    wrong-node) printf 'other-node\tqos-validation\trunning\n' ;;
    *) printf 'qos-123-1\tqos-validation\trunning\n' ;;
  esac
elif [[ "$1" == "inspect" ]]; then
  [[ "$*" == *'buildx_buildkit_qos-123-1'* ]] || exit 65
  case "${MOCK_SCENARIO}" in
    inspect-failure) exit 66 ;;
    multi-container)
      printf 'id-one\t/buildx_buildkit_qos-123-1\trunning\tmoby/buildkit:v0.32.2\tsha256:one\n'
      printf 'id-two\t/buildx_buildkit_qos-123-1\trunning\tmoby/buildkit:v0.32.2\tsha256:two\n'
      ;;
    stopped) printf 'id-one\t/buildx_buildkit_qos-123-1\texited\tmoby/buildkit:v0.32.2\tsha256:one\n' ;;
    *) printf 'id-one\t/buildx_buildkit_qos-123-1\trunning\tmoby/buildkit:v0.32.2\tsha256:one\n' ;;
  esac
else
  exit 64
fi
EOF
chmod +x "${tmp}/bin/docker"
: >"${tmp}/docker.log"

run_gate() {
  env PATH="${tmp}/bin:${PATH}" MOCK_DOCKER_LOG="${tmp}/docker.log" \
    MOCK_SCENARIO="$1" "$entry" qos-123-1 qos-123-1 qos-validation
}

output="$(run_gate success)"
[[ "$output" == *'buildkit_container=buildx_buildkit_qos-123-1'* ]] || fail 'exact container was not reported'
[[ "$output" == *'buildkit_image_ref=moby/buildkit:v0.32.2'* ]] || fail 'image ref was not reported'
[[ "$output" == *'buildkit_image_id=sha256:one'* ]] || fail 'image ID was not reported'
refute_log="$(<"${tmp}/docker.log")"
[[ "$refute_log" != *'label='* ]] || fail 'gate queried the unsupported Buildx label'

assert_fails 'expected exactly one Buildx node, found 0' run_gate zero-node
assert_fails 'expected exactly one Buildx node, found 2' run_gate multi-node
assert_fails 'unexpected Buildx node name' run_gate wrong-node
assert_fails 'unexpected Buildx endpoint' run_gate wrong-endpoint
assert_fails 'expected exactly one BuildKit container record, found 2' run_gate multi-container
assert_fails 'BuildKit container is not running' run_gate stopped
assert_fails 'docker inspect failed' run_gate inspect-failure

: >"${tmp}/docker.log"
assert_fails 'builder must use safe name characters' env \
  PATH="${tmp}/bin:${PATH}" MOCK_DOCKER_LOG="${tmp}/docker.log" MOCK_SCENARIO=success \
  "$entry" 'bad/builder' qos-123-1 qos-validation
[[ ! -s "${tmp}/docker.log" ]] || fail 'malformed builder reached Docker'

echo '8 Buildx container gate behavior tests passed'
