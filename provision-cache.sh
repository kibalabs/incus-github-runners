#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

BUILDKIT_IMAGE="moby/buildkit:v0.33.1"

if ! command -v docker >/dev/null; then
  apt-get update
  apt-get install -y docker.io
fi

docker pull "$BUILDKIT_IMAGE"
docker rm --force buildkitd >/dev/null 2>&1 || true
docker run --detach --name buildkitd --restart always --privileged \
  --publish 1234:1234 \
  --add-host buildkit:host-gateway \
  --volume buildkit:/var/lib/buildkit \
  --volume /etc/buildkit:/etc/buildkit:ro \
  "$BUILDKIT_IMAGE"
