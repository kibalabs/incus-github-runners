#!/usr/bin/env bash
set -euo pipefail

REGISTRY_IMAGE="registry:3.1.2"

docker pull "$REGISTRY_IMAGE"
docker rm --force registry >/dev/null 2>&1 || true
docker volume rm --force registry >/dev/null
docker run --detach --name registry --restart always \
  --publish 5000:5000 \
  --volume registry:/var/lib/registry \
  "$REGISTRY_IMAGE"
