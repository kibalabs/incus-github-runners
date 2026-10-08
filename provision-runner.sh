#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git jq make unzip

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" >/etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
echo '{"insecure-registries": ["buildkit:5000"]}' >/etc/docker/daemon.json

cat >/usr/local/bin/prepull-images <<'EOF'
#!/usr/bin/env bash
# Report every free page to the host, not just 2MB blocks: after pulling, free memory is too fragmented for those.
echo 0 >/sys/module/page_reporting/parameters/page_reporting_order
for repository in $(curl -fsS 'http://buildkit:5000/v2/_catalog?n=1000' | jq -r '.repositories[]'); do
  docker pull --quiet "buildkit:5000/$repository:latest" &
done
wait
# The pulled layers stay in the page cache; drop it so free page reporting hands that memory back to the host.
sync
echo 3 >/proc/sys/vm/drop_caches
echo 1 >/proc/sys/vm/compact_memory
EOF
chmod 755 /usr/local/bin/prepull-images

useradd --create-home --shell /bin/bash --groups docker runner
echo 'runner ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/runner
chmod 440 /etc/sudoers.d/runner

mkdir /home/runner/actions-runner
curl -fsSL "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz" | tar -xz -C /home/runner/actions-runner
/home/runner/actions-runner/bin/installdependencies.sh
# Read by the runner at start and passed to every job; kibalabs/github-action-build-image uses them to build on the cache VM.
cat >/home/runner/actions-runner/.env <<'EOF'
BUILDKIT_ENDPOINT=tcp://buildkit:1234
BUILDKIT_REGISTRY=buildkit:5000
EOF
chown -R runner:runner /home/runner
