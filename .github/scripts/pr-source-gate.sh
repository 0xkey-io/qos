#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "pr-source-gate: $*" >&2
  exit 1
}

validate_sha() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || \
    die "${name} must be exactly 40 lowercase hexadecimal characters"
}

repo="${1:-}"
[[ -n "$repo" ]] || die 'repository path is required'
[[ -n "${GITHUB_OUTPUT:-}" ]] || die 'GITHUB_OUTPUT is required'

event_name="${GITHUB_EVENT_NAME:-}"
event_ref="${GITHUB_REF:-}"
event_sha="${GITHUB_SHA:-}"
validate_sha GITHUB_SHA "$event_sha"

actual_sha="$(git -C "$repo" rev-parse HEAD)"
[[ "$actual_sha" = "$event_sha" ]] || \
  die "checked-out HEAD ${actual_sha} does not match event SHA ${event_sha}"

case "$event_name" in
  pull_request)
    pr_number="${PR_NUMBER:-}"
    base_sha="${BASE_SHA:-}"
    head_sha="${HEAD_SHA:-}"
    [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || die 'PR_NUMBER must be numeric and positive'
    [[ "$event_ref" = "refs/pull/${pr_number}/merge" ]] || \
      die "GITHUB_REF must be refs/pull/${pr_number}/merge"
    validate_sha BASE_SHA "$base_sha"
    validate_sha HEAD_SHA "$head_sha"

    read -r -a commit_line <<<"$(git -C "$repo" rev-list --parents -n 1 HEAD)"
    [[ "${#commit_line[@]}" -eq 3 ]] || die 'pull request merge commit must have exactly two parents'
    [[ "${commit_line[1]}" = "$base_sha" ]] || die 'merge first parent does not match base SHA'
    [[ "${commit_line[2]}" = "$head_sha" ]] || die 'merge second parent does not match head SHA'
    ;;
  push)
    [[ "$event_ref" = 'refs/heads/main' ]] || die 'push GITHUB_REF must be refs/heads/main'
    ;;
  *)
    die "unsupported event ${event_name:-<empty>}"
    ;;
esac

source_tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
validate_sha source_tree "$source_tree"

if ! printf 'source_sha=%s\nsource_tree=%s\n' "$actual_sha" "$source_tree" >>"$GITHUB_OUTPUT"; then
  die 'could not write GITHUB_OUTPUT'
fi
printf 'event=%s\nref=%s\nsource_sha=%s\nsource_tree=%s\n' \
  "$event_name" "$event_ref" "$actual_sha" "$source_tree"
