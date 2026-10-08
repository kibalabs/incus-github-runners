#!/usr/bin/env bash
set -euo pipefail

RUNNERS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$(cd "${GHR_CONFIG_DIR:-$RUNNERS_DIR}" && pwd)"
export GHR_CONFIG_DIR="$CONFIG_DIR"
NAME="$(jq -r .name "$CONFIG_DIR/config.json")"
BASE_IMAGE="images:ubuntu/24.04/cloud"
IMAGE_ALIAS="$NAME-runner"
BUILD_VM="$NAME-image-build"

wait_for_vm() {
  local name="$1"
  for _ in $(seq 90); do
    if incus exec "$name" -- true </dev/null >/dev/null 2>&1; then
      incus exec "$name" -- cloud-init status --wait </dev/null >/dev/null || true
      return
    fi
    sleep 2
  done
  echo "Timed out waiting for $name to boot" >&2
  return 1
}

wait_for_idle_runners() {
  local deadline=$((SECONDS + 3600))
  until python3 "$RUNNERS_DIR/pool.py" --check-busy-runners; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 30
  done
}

image_fingerprint() {
  incus image list --format json | jq -r --arg alias "$1" '.[] | select(any(.aliases[]?; .name == $alias)) | .fingerprint'
}

discard_next_image() {
  local nextFingerprint currentFingerprint
  nextFingerprint="$(image_fingerprint "$IMAGE_ALIAS-next")"
  if [[ -z "$nextFingerprint" ]]; then
    return
  fi
  currentFingerprint="$(image_fingerprint "$IMAGE_ALIAS")"
  if [[ "$nextFingerprint" == "$currentFingerprint" ]]; then
    incus image alias delete "$IMAGE_ALIAS-next" >/dev/null 2>&1 || true
  else
    incus image delete "$nextFingerprint" >/dev/null 2>&1 || true
  fi
}

trap 'incus delete --force "$BUILD_VM" >/dev/null 2>&1 || true' EXIT
incus delete --force "$BUILD_VM" >/dev/null 2>&1 || true
discard_next_image

runnerVersion="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name)"
runnerVersion="${runnerVersion#v}"
echo "Building $IMAGE_ALIAS with actions runner $runnerVersion"

incus launch "$BASE_IMAGE" "$BUILD_VM" --vm --profile "$NAME-build"
wait_for_vm "$BUILD_VM"
incus exec "$BUILD_VM" --env RUNNER_VERSION="$runnerVersion" -- bash -s <"$RUNNERS_DIR/provision-runner.sh"
if [[ -f "$CONFIG_DIR/provision-extra.sh" ]]; then
  echo "Running $CONFIG_DIR/provision-extra.sh"
  incus exec "$BUILD_VM" -- bash -s <"$CONFIG_DIR/provision-extra.sh"
fi
incus exec "$BUILD_VM" -- sh -c 'apt-get clean && cloud-init clean --logs --machine-id'
incus stop "$BUILD_VM"

oldFingerprint="$(image_fingerprint "$IMAGE_ALIAS")"
incus publish "$BUILD_VM" --alias "$IMAGE_ALIAS-next" --compression none
newFingerprint="$(image_fingerprint "$IMAGE_ALIAS-next")"
if [[ -z "$newFingerprint" ]]; then
  echo "Failed to find the newly published image fingerprint" >&2
  exit 1
fi
if [[ -n "$oldFingerprint" ]]; then
  incus query -X PATCH "/1.0/images/aliases/$IMAGE_ALIAS" --data "{\"target\":\"$newFingerprint\"}"
else
  incus image alias create "$IMAGE_ALIAS" "$newFingerprint"
fi
incus image alias delete "$IMAGE_ALIAS-next"
if [[ -n "$oldFingerprint" && "$oldFingerprint" != "$newFingerprint" ]]; then
  incus image delete "$oldFingerprint"
fi
echo "Published $IMAGE_ALIAS ($(image_fingerprint "$IMAGE_ALIAS"))"

if wait_for_idle_runners; then
  for org in $(jq -r '.orgs[].name' "$CONFIG_DIR/config.json"); do
    incus exec "$NAME-$org-cache" -- bash -s <"$RUNNERS_DIR/reset-registry.sh"
  done
  echo "Emptied the image registries"
else
  echo "Runners were still busy (or GitHub couldn't be checked) for an hour, skipped emptying the image registries this week" >&2
fi
