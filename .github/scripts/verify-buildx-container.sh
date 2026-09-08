#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "verify-buildx-container: $*" >&2
  exit 1
}

builder="${1:-}"
expected_node="${2:-}"
expected_endpoint="${3:-}"
safe_name='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
[[ "$builder" =~ $safe_name ]] || die 'builder must use safe name characters'
[[ "$expected_node" =~ $safe_name ]] || die 'node must use safe name characters'
[[ "$expected_endpoint" =~ $safe_name ]] || die 'endpoint must use safe name characters'

node_format='{{range .Nodes}}{{printf "%s\t%s\t%s\n" .Name .Endpoint .Status}}{{end}}'
if ! node_output="$(docker buildx inspect "$builder" --format "$node_format" 2>&1)"; then
  die "docker buildx inspect failed: ${node_output}"
fi
node_records=()
while IFS= read -r record; do
  [[ -z "$record" ]] || node_records+=("$record")
done <<<"$node_output"
[[ "${#node_records[@]}" -eq 1 ]] || \
  die "expected exactly one Buildx node, found ${#node_records[@]} (builder=${builder}, expected_node=${expected_node})"

IFS=$'\t' read -r actual_node actual_endpoint actual_status extra <<<"${node_records[0]}"
[[ -z "${extra:-}" ]] || die 'Buildx node record has unexpected fields'
[[ "$actual_node" == "$expected_node" ]] || \
  die "unexpected Buildx node name (expected=${expected_node}, actual=${actual_node:-<empty>})"
[[ "$actual_endpoint" == "$expected_endpoint" ]] || \
  die "unexpected Buildx endpoint (expected=${expected_endpoint}, actual=${actual_endpoint:-<empty>})"
[[ "$actual_status" == 'running' ]] || \
  die "Buildx node is not running (node=${actual_node}, status=${actual_status:-<empty>})"

expected_container="buildx_buildkit_${expected_node}"
container_format='{{printf "%s\t%s\t%s\t%s\t%s\n" .Id .Name .State.Status .Config.Image .Image}}'
if ! container_output="$(docker inspect --type container --format "$container_format" "$expected_container" 2>&1)"; then
  die "docker inspect failed for ${expected_container}: ${container_output}"
fi
container_records=()
while IFS= read -r record; do
  [[ -z "$record" ]] || container_records+=("$record")
done <<<"$container_output"
[[ "${#container_records[@]}" -eq 1 ]] || \
  die "expected exactly one BuildKit container record, found ${#container_records[@]} (container=${expected_container})"

IFS=$'\t' read -r container_id container_name container_status image_ref image_id extra \
  <<<"${container_records[0]}"
[[ -z "${extra:-}" ]] || die 'BuildKit container record has unexpected fields'
[[ "$container_name" == "/${expected_container}" ]] || \
  die "unexpected BuildKit container name (expected=/${expected_container}, actual=${container_name:-<empty>})"
[[ "$container_status" == 'running' ]] || \
  die "BuildKit container is not running (container=${expected_container}, status=${container_status:-<empty>})"
[[ -n "$container_id" && -n "$image_ref" && -n "$image_id" ]] || \
  die 'BuildKit container record is incomplete'

printf 'buildx_builder=%s\nbuildx_node=%s\nbuildx_endpoint=%s\n' \
  "$builder" "$actual_node" "$actual_endpoint"
printf 'buildkit_container=%s\nbuildkit_container_id=%s\n' \
  "$expected_container" "$container_id"
printf 'buildkit_image_ref=%s\nbuildkit_image_id=%s\n' "$image_ref" "$image_id"
