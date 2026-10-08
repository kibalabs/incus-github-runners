#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0 [config-dir]" >&2
  exit 1
fi

RUNNERS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$(cd "${1:-$RUNNERS_DIR}" && pwd)"
CONFIG="$CONFIG_DIR/config.json"
PRIVATE_KEY="$CONFIG_DIR/secrets/github-app.pem"
BASE_IMAGE="images:ubuntu/24.04/cloud"

fail() {
  echo "$1" >&2
  exit 1
}

config() {
  jq -r "$1" "$CONFIG"
}

# Sizes as in config.json: 3GiB, 512MiB or 24G (G meaning GiB, as systemd reads it).
to_bytes() {
  local size="${1%B}"
  if [[ "$size" == *i ]]; then
    numfmt --from=iec-i "$size"
  else
    numfmt --from=iec "$size"
  fi
}

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

setup_network() {
  local name="$1" index="$2"
  local subnet="$SUBNET_PREFIX.$index"
  if ! incus network show "$name" >/dev/null 2>&1; then
    incus network create "$name" ipv4.address="$subnet.1/24" ipv4.nat=true ipv4.dhcp.ranges="$subnet.10-$subnet.250" ipv6.address=none
  fi
  if ! incus network acl show "$name" >/dev/null 2>&1; then
    incus network acl create "$name"
  fi
  # Incus applies drop rules before allow rules, so allowed private addresses are cut out of the dropped ranges instead.
  local dropDestinations
  dropDestinations="$(python3 - "$subnet.2" "$(config '.allowedPrivateDestinations // [] | join(",")')" <<'EOF'
import ipaddress
import sys

blockedNetworks = [ipaddress.ip_network(network) for network in ('10.0.0.0/8', '100.64.0.0/10', '169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/4')]
allowedNetworks = [ipaddress.ip_network(network, strict=False) for network in [sys.argv[1], *filter(None, sys.argv[2].split(','))]]
for allowedNetwork in allowedNetworks:
    blockedNetworks = [part for network in blockedNetworks for part in ([network] if not network.overlaps(allowedNetwork) else list(network.address_exclude(allowedNetwork)) if allowedNetwork.subnet_of(network) else [])]
print(','.join(str(network) for network in ipaddress.collapse_addresses(blockedNetworks)))
EOF
)"
  incus network acl edit "$name" <<EOF
description: Internet, the org cache VM ($subnet.2) and allowedPrivateDestinations only.
egress:
  - action: drop
    state: enabled
    destination: $dropDestinations
  - action: allow
    state: enabled
ingress: []
EOF
  incus network set "$name" security.acls="$name" security.acls.default.egress.action=drop security.acls.default.ingress.action=drop
  if [[ "$UFW_ACTIVE" == true ]]; then
    ufw allow in on "$name" to any port 53 >/dev/null
    ufw allow in on "$name" to any port 67 proto udp >/dev/null
    ufw route allow in on "$name" out on "$WAN_INTERFACE" >/dev/null
    ufw route allow in on "$name" out on "$name" >/dev/null
  fi
}

setup_profile() {
  local name="$1" network="$2" cpus="$3" memory="$4" disk="$5" autostart="$6" ipv4Address="${7:-}" freePageReporting="${8:-false}"
  local extraConfig=""
  if [[ $freePageReporting == true ]]; then
    # Lets QEMU give memory the guest frees back to the host; otherwise every VM keeps its peak usage forever.
    extraConfig='  raw.qemu.conf: |-
    [device "qemu_balloon"]
    free-page-reporting = "on"'
  fi
  if ! incus profile show "$name" >/dev/null 2>&1; then
    incus profile create "$name"
  fi
  incus profile edit "$name" <<EOF
config:
  boot.autostart: "$autostart"
  limits.cpu: "$cpus"
  limits.memory: $memory
$extraConfig
devices:
  root:
    type: disk
    path: /
    pool: $NAME
    size: $disk
  eth0:
    type: nic
    network: $network
    security.mac_filtering: "true"
    security.ipv4_filtering: "true"
${ipv4Address:+    ipv4.address: $ipv4Address}
EOF
}

setup_cache_vm() {
  local name="$1"
  if ! incus info "$name" >/dev/null 2>&1; then
    incus launch "$BASE_IMAGE" "$name" --vm --profile "$name"
  elif [[ "$(incus list "^$name\$" --format csv --columns s)" != "RUNNING" ]]; then
    incus start "$name"
  fi
  wait_for_vm "$name"
  incus exec "$name" -- mkdir -p /etc/buildkit
  incus file push "$RUNNERS_DIR/buildkitd.toml" "$name/etc/buildkit/buildkitd.toml"
  incus exec "$name" -- bash -s <"$RUNNERS_DIR/provision-cache.sh"
  incus exec "$name" -- bash -s <"$RUNNERS_DIR/reset-registry.sh"
}

command -v apt-get >/dev/null || fail "This needs Debian or Ubuntu (apt)"
[[ "$(uname -m)" == x86_64 ]] || fail "This needs an x86_64 machine"
[[ -e /dev/kvm ]] || fail "No /dev/kvm: enable virtualization (VT-x / AMD-V) in the BIOS, or nested virtualization if this machine is itself a VM"
[[ -f "$CONFIG" ]] || fail "Missing $CONFIG: copy config.example.json there and fill it in (see README.md)"
[[ -f "$PRIVATE_KEY" ]] || fail "Missing $PRIVATE_KEY: the GitHub App's private key (see README.md)"
chmod 600 "$PRIVATE_KEY"

export DEBIAN_FRONTEND=noninteractive
apt-get update
# Ubuntu's incus package doesn't pull in QEMU and the UEFI firmware, which Incus needs to run VMs.
apt-get install -y incus qemu-system-x86 ovmf btrfs-progs jq python3

[[ "$(config .githubAppId)" =~ ^[0-9]+$ ]] || fail "Set githubAppId in $CONFIG (see README.md)"
NAME="$(config .name)"
[[ "$NAME" =~ ^[a-z][a-z0-9]{0,9}$ ]] || fail "name in $CONFIG must be 1-10 lowercase letters or digits, starting with a letter (it prefixes network interfaces)"
SUBNET_PREFIX="$(config .subnetPrefix)"
[[ "$SUBNET_PREFIX" =~ ^[0-9]{1,3}\.[0-9]{1,3}$ ]] || fail "subnetPrefix in $CONFIG must be the first two parts of an IPv4 address, e.g. 10.77"
neededMemory="$(( ($(config '[.orgs[].jobVmCount] | add') * $(to_bytes "$(config .jobVm.memory)")) + ($(config '.orgs | length') * $(to_bytes "$(config .cacheVm.memory)")) ))"
vmMemoryLimit="$(to_bytes "$(config .vmMemoryLimit)")"
hostMemory="$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) * 1024 ))"
(( neededMemory <= vmMemoryLimit )) || fail "The job VMs and cache VMs need $(numfmt --to=iec-i "$neededMemory")B but vmMemoryLimit is $(config .vmMemoryLimit): lower jobVmCount or the VM memory, or raise vmMemoryLimit"
(( vmMemoryLimit < hostMemory )) || fail "vmMemoryLimit ($(config .vmMemoryLimit)) must leave memory for the host, which has $(numfmt --to=iec-i "$hostMemory")B"

UFW_ACTIVE=false
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  UFW_ACTIVE=true
elif command -v docker >/dev/null; then
  echo "Warning: Docker is installed and ufw is not active. Docker sets the firewall's forwarding policy to drop, which can cut the VMs off from the internet (see README.md)." >&2
fi

AGENT_PATH_CONF=/etc/systemd/system/incus.service.d/agent-path.conf
agentPathConf="# Ubuntu's incus.service reads /etc/environment after /etc/default/incus, which drops /usr/libexec/incus
# from PATH, so incusd can't find incus-agent and VMs boot without it.
[Service]
EnvironmentFile=
EnvironmentFile=-/etc/environment
EnvironmentFile=/etc/default/incus"
if [[ "$(cat "$AGENT_PATH_CONF" 2>/dev/null)" != "$agentPathConf" ]]; then
  # Restarting incusd stops the ephemeral job VMs, so only do it when the override changes.
  mkdir -p "$(dirname "$AGENT_PATH_CONF")"
  echo "$agentPathConf" >"$AGENT_PATH_CONF"
  systemctl daemon-reload
  systemctl restart incus.service
fi
systemctl enable --now incus.service
# Every VM runs inside incus.service. Capping it (with no swap) makes a VM get killed when VM memory runs out, instead of the whole host freezing.
systemctl set-property incus.service MemoryMax="$(config .vmMemoryLimit)" MemorySwapMax=0
if [[ -n "${SUDO_USER:-}" ]]; then
  usermod -aG incus-admin "$SUDO_USER"
fi
# Incus only looks for QEMU when it starts, so it may still be running without VM support from before QEMU was installed.
if ! incus info | grep -q '^  driver: .*qemu'; then
  systemctl restart incus.service
fi

if ! incus info | grep 'firewall: nftables' >/dev/null; then
  fail "Incus is not using the nftables firewall driver, so the network ACLs would not be enforced"
fi

WAN_INTERFACE="$(ip -o route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}')"

if ! incus storage show "$NAME" >/dev/null 2>&1; then
  incus storage create "$NAME" btrfs size="$(config .storagePoolSize)"
fi

setup_network "${NAME}0" 0
setup_profile "$NAME-build" "${NAME}0" 4 4GiB 10GiB false

orgCount="$(config '.orgs | length')"
for ((i = 0; i < orgCount; i++)); do
  org="$(config ".orgs[$i].name")"
  index="$(config ".orgs[$i].networkIndex")"
  network="$NAME$index"
  setup_network "$network" "$index"
  setup_profile "$NAME-$org-job" "$network" "$(config .jobVm.cpus)" "$(config .jobVm.memory)" "$(config .jobVm.disk)" false "" true
  setup_profile "$NAME-$org-cache" "$network" "$(config .cacheVm.cpus)" "$(config .cacheVm.memory)" "$(config .cacheVm.disk)" true "$SUBNET_PREFIX.$index.2"
  setup_cache_vm "$NAME-$org-cache"
done

if ! incus image show "$NAME-runner" >/dev/null 2>&1; then
  GHR_CONFIG_DIR="$CONFIG_DIR" "$RUNNERS_DIR/build-image.sh"
fi

cat >"/etc/systemd/system/$NAME-pool.service" <<EOF
[Unit]
Description=GitHub Actions runner pool ($CONFIG_DIR)
Requires=incus.service
After=incus.service network-online.target
Wants=network-online.target

[Service]
Environment=GHR_CONFIG_DIR=$CONFIG_DIR
ExecStart=/usr/bin/python3 $RUNNERS_DIR/pool.py
Restart=always
RestartSec=30
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF

cat >"/etc/systemd/system/$NAME-image.service" <<EOF
[Unit]
Description=Rebuild the GitHub Actions runner VM image ($CONFIG_DIR)
Requires=incus.service
After=incus.service network-online.target

[Service]
Type=oneshot
Environment=GHR_CONFIG_DIR=$CONFIG_DIR
ExecStart=$RUNNERS_DIR/build-image.sh
EOF

cat >"/etc/systemd/system/$NAME-image.timer" <<EOF
[Unit]
Description=Weekly rebuild of the GitHub Actions runner VM image

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "$NAME-image.timer" "$NAME-pool.service"
echo "Runner pool is running. Follow it with: journalctl -fu $NAME-pool"
echo "After changing config.json or updating this repo, run this script again, then: sudo systemctl restart $NAME-pool"
