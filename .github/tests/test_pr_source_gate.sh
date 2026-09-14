#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
entry="${repo_root}/.github/scripts/pr-source-gate.sh"

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

make_merge_repo() {
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config user.name 'QoS CI test'
  git -C "$repo" config user.email 'qos-ci-test@example.invalid'
  git -C "$repo" commit -q --allow-empty -m root
  git -C "$repo" branch base-branch
  git -C "$repo" checkout -q -b fork-branch
  git -C "$repo" commit -q --allow-empty -m head
  head_sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -q base-branch
  git -C "$repo" commit -q --allow-empty -m base
  base_sha="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" merge -q --no-ff fork-branch -m merge
  event_sha="$(git -C "$repo" rev-parse HEAD)"
  event_tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
}

run_pr() {
  local repo="$1" output_file="$2"
  env GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/73/merge \
    GITHUB_SHA="$event_sha" PR_NUMBER=73 BASE_SHA="$base_sha" HEAD_SHA="$head_sha" \
    GITHUB_OUTPUT="$output_file" "$entry" "$repo"
}

test_matching_merge_exports_only_validated_source() {
  local tmp output
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_merge_repo "${tmp}/repo"

  output="$(run_pr "${tmp}/repo" "${tmp}/output")"
  [[ "$output" == *"source_sha=${event_sha}"* ]] || fail 'source SHA missing from log'
  [[ "$output" == *"source_tree=${event_tree}"* ]] || fail 'source tree missing from log'
  [[ "$(<"${tmp}/output")" == $'source_sha='"${event_sha}"$'\nsource_tree='"${event_tree}" ]] || \
    fail 'output file did not contain exactly the validated source identity'
}

test_wrong_head_parent_order_single_parent_and_event_sha_fail_closed() {
  local tmp output_file wrong_sha single_sha
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_merge_repo "${tmp}/repo"
  output_file="${tmp}/output"
  wrong_sha="$(git -C "${tmp}/repo" rev-parse HEAD^)"

  assert_fails 'second parent' env GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/73/merge \
    GITHUB_SHA="$event_sha" PR_NUMBER=73 BASE_SHA="$base_sha" HEAD_SHA="$wrong_sha" \
    GITHUB_OUTPUT="$output_file" "$entry" "${tmp}/repo"
  [[ ! -e "$output_file" ]] || fail 'failed validation emitted outputs'

  assert_fails 'first parent' env GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/73/merge \
    GITHUB_SHA="$event_sha" PR_NUMBER=73 BASE_SHA="$head_sha" HEAD_SHA="$base_sha" \
    GITHUB_OUTPUT="$output_file" "$entry" "${tmp}/repo"
  [[ ! -e "$output_file" ]] || fail 'wrong parent order emitted outputs'

  single_sha="$(git -C "${tmp}/repo" rev-parse HEAD^1)"
  git -C "${tmp}/repo" checkout -q --detach "$single_sha"
  assert_fails 'exactly two parents' env GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/73/merge \
    GITHUB_SHA="$single_sha" PR_NUMBER=73 BASE_SHA="$base_sha" HEAD_SHA="$head_sha" \
    GITHUB_OUTPUT="$output_file" "$entry" "${tmp}/repo"
  [[ ! -e "$output_file" ]] || fail 'single-parent validation emitted outputs'

  git -C "${tmp}/repo" checkout -q --detach "$event_sha"
  assert_fails 'does not match event SHA' env GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/73/merge \
    GITHUB_SHA=ffffffffffffffffffffffffffffffffffffffff PR_NUMBER=73 BASE_SHA="$base_sha" HEAD_SHA="$head_sha" \
    GITHUB_OUTPUT="$output_file" "$entry" "${tmp}/repo"
  [[ ! -e "$output_file" ]] || fail 'event mismatch emitted outputs'
}

test_refs_identifiers_and_push_main_are_strict() {
  local tmp output_file
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_merge_repo "${tmp}/repo"
  output_file="${tmp}/output"

  assert_fails 'GITHUB_REF' env GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$event_sha" PR_NUMBER=73 BASE_SHA="$base_sha" HEAD_SHA="$head_sha" \
    GITHUB_OUTPUT="$output_file" "$entry" "${tmp}/repo"
  assert_fails 'PR_NUMBER' env GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/73/merge \
    GITHUB_SHA="$event_sha" PR_NUMBER='73/x' BASE_SHA="$base_sha" HEAD_SHA="$head_sha" \
    GITHUB_OUTPUT="$output_file" "$entry" "${tmp}/repo"
  assert_fails 'lowercase hexadecimal' env GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/73/merge \
    GITHUB_SHA="${event_sha^^}" PR_NUMBER=73 BASE_SHA="$base_sha" HEAD_SHA="$head_sha" \
    GITHUB_OUTPUT="$output_file" "$entry" "${tmp}/repo"
  assert_fails 'unsupported event' env GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$event_sha" GITHUB_OUTPUT="$output_file" "$entry" "${tmp}/repo"

  env GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main GITHUB_SHA="$event_sha" \
    GITHUB_OUTPUT="$output_file" "$entry" "${tmp}/repo" >/dev/null
  grep -qx "source_sha=${event_sha}" "$output_file" || fail 'push-main did not export source SHA'
}

test_output_write_failure_is_fatal() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  make_merge_repo "${tmp}/repo"
  mkdir "${tmp}/output-dir"
  assert_fails 'could not write GITHUB_OUTPUT' run_pr "${tmp}/repo" "${tmp}/output-dir"
}

test_matching_merge_exports_only_validated_source
test_wrong_head_parent_order_single_parent_and_event_sha_fail_closed
test_refs_identifiers_and_push_main_are_strict
test_output_write_failure_is_fatal
echo '4 PR source gate behavior tests passed'
