# Incus GitHub Runners

Ephemeral, fast GitHub Actions runners on your own Linux machine: every job runs in a fresh VM, and image builds share one warm BuildKit cache.

Made for an office or home server running CI for one or more GitHub organisations. One `config.json`, one GitHub App, one setup script.

## How it works

- **Job VMs**: every job runs in a fresh KVM virtual machine (managed by [Incus](https://linuxcontainers.org/incus/)), registered with GitHub as a one-time (JIT) runner. The VM is deleted when the job finishes, so no state leaks between jobs.
- **Cache VM**: each org has one long-lived VM (`<name>-<org>-cache`, reachable from job VMs as `buildkit`) running BuildKit (`:1234`) and an image registry (`:5000`). Builds run on BuildKit, so layers stay cached between jobs, and images that jobs need locally go through the registry instead of being loaded.
- **Image pre-pull**: while waiting for a job, each job VM pulls the latest image of every repository in the registry, so a job only downloads the layers its build changed. Afterwards the VM hands its free memory back to the host, so an idle job VM holds ~0.8GiB.
- **Network**: each org has its own bridge. VMs can reach the internet, their org's cache VM and `allowedPrivateDestinations`, but not the host, the LAN or other private addresses.
- **Pool manager**: `pool.py` (systemd `<name>-pool`) keeps `jobVmCount` idle job VMs per org and replaces each VM after its job.
- **Image refresh**: `build-image.sh` (systemd timer `<name>-image.timer`, weekly) rebuilds the job VM image with the latest actions runner. Within 5 minutes the pool replaces idle job VMs built from the old image; busy ones finish their job first. Each org's registry is emptied once no runner is busy.

Pair it with these actions to get the most out of the cache:

- [`kibalabs/github-action-build-image`](https://github.com/kibalabs/github-action-build-image): builds on the cache VM's BuildKit (job VMs set `BUILDKIT_ENDPOINT` and `BUILDKIT_REGISTRY`), and falls back to the GitHub Actions cache on GitHub's runners.
- [`kibalabs/github-action-run-docker-checks`](https://github.com/kibalabs/github-action-run-docker-checks): runs checks in parallel containers of the built image, each as its own PR check.
- [`kibalabs/github-action-skip-if-passed`](https://github.com/kibalabs/github-action-skip-if-passed): skips jobs whose files already passed.

## Requirements

- An x86_64 machine running Ubuntu (tested on 24.04 and 25.10), with virtualization enabled in the BIOS. A VM works too, with nested virtualization.
- Enough memory: `jobVmCount` × job VM memory + one cache VM per org, plus headroom for the host. 32GB runs 4 job VMs comfortably.
- A few hundred GB of disk for the storage pool (the cache VM's disk holds the build cache).

## Setup

### 1. Create a GitHub App (once)

1. Open https://github.com/settings/apps/new (or your organisation's **Settings → Developer settings → GitHub Apps**).
2. **GitHub App name**: anything unique, e.g. `acme-office-runners`. **Homepage URL**: any URL, e.g. this repository.
3. **Webhook**: untick **Active**.
4. **Permissions → Organization permissions → Self-hosted runners**: **Read and write**. Nothing else.
5. **Where can this GitHub App be installed?**: **Any account** if one machine should serve several organisations, otherwise **Only on this account**.
6. Click **Create GitHub App** and note the **App ID**.
7. Under **Private keys**, click **Generate a private key**.
8. Click **Install App** and install it on each organisation the machine should serve.

### 2. Configure

Keep the configuration outside this repository, so updating it is a plain `git pull`:

```sh
git clone https://github.com/kibalabs/incus-github-runners.git
mkdir -p runner-config/secrets
cp incus-github-runners/config.example.json runner-config/config.json
cp ~/Downloads/your-app.private-key.pem runner-config/secrets/github-app.pem
```

Then edit `runner-config/config.json`:

| Field | Description |
| --- | --- |
| `name` | Prefix for every Incus resource, systemd unit and GitHub runner name (1-10 lowercase letters or digits). Machines serving the same org need different names, or they remove each other's runners. |
| `githubAppId` | The App ID from step 1. |
| `runnerLabels` | Labels of the runners; workflows pick them with `runs-on`. |
| `runnerGroupId` | Runner group to add the runners to; `1` is the org's Default group. |
| `subnetPrefix` | First two parts of the VM networks' addresses: org `networkIndex` *n* gets `<subnetPrefix>.n.0/24`, and `0` is used to build the image. Pick one your LAN and VPNs don't use. |
| `allowedPrivateDestinations` | Private addresses or CIDRs job VMs may reach, e.g. `["192.168.1.20/32"]` for an internal package mirror. Everything else private is blocked. |
| `storagePoolSize` | Size of the Incus storage pool holding every VM's disk. |
| `vmMemoryLimit` | Memory cap for all VMs together (systemd `MemoryMax` of `incus.service`, `G` meaning GiB). |
| `cacheVm`, `jobVm` | CPUs, memory and disk of each VM. |
| `orgs` | Each org: `name`, an unused `networkIndex` (1 or more) and `jobVmCount`. |

To install more tools in the job VMs (e.g. a cloud CLI), put a `provision-extra.sh` next to `config.json`. It runs as root in the image build after the base setup (Docker, git, curl, jq, make, unzip, the actions runner).

### 3. Set up the host

```sh
sudo incus-github-runners/setup-host.sh runner-config
```

It checks the machine and the config, installs Incus, creates the storage pool, networks, network ACLs, cache VMs and the job VM image, then installs and starts `<name>-pool` and the weekly `<name>-image` timer. The first run takes about 10 minutes. It's safe to run again after changing `config.json`; then restart the pool with `sudo systemctl restart <name>-pool`.

Your user is added to `incus-admin`; log in again to use `incus` without `sudo`.

### 4. Use it in workflows

```yaml
jobs:
  build:
    runs-on: [self-hosted, incus]
```

To fall back to GitHub's runners when the machine is down, pick the runner through a variable: `runs-on: ${{ vars.CI_RUNNER || 'incus' }}`, and set the org or repo Actions variable `CI_RUNNER` to `ubuntu-latest` to switch (delete it to switch back).

Runners in the Default group are only offered to private repositories. Keep public repositories on GitHub's runners, which are free for them, and see the trust model below before changing that.

## Sizing

Every VM runs inside `incus.service`, capped at `vmMemoryLimit` with no swap. A busy job VM fills its memory with file cache, and the cache VM keeps its memory full with BuildKit's file cache, so the setup script checks that every VM at full memory fits under the cap: `jobVmCount` × job VM memory, plus each org's cache VM, plus the 4GiB VM the weekly image build starts, plus 256MiB per VM and 512MiB for Incus itself. The example config (4 × 3GiB job VMs and a 6GiB cache VM) needs exactly 24GiB.

If VMs still reach the cap, the kernel kills a job VM (the pool marks them as first to go) rather than the cache VM or anything on the host, and that job fails. The setup script sets `OOMPolicy=continue` on `incus.service`, so the other VMs keep running; systemd's default would stop all of Incus.

The cache VM's memory is only a page cache for BuildKit's layers, which live on its disk, so a smaller cache VM costs a little speed rather than cache hits.

## Operating

- Logs: `journalctl -fu <name>-pool`
- VMs: `incus list`
- Cache disk use: `incus exec <name>-<org>-cache -- docker exec buildkitd buildctl du | tail -1`
- Clear an org's build cache: `incus exec <name>-<org>-cache -- docker exec buildkitd buildctl prune --all`
- Rebuild the job image now: `sudo systemctl start <name>-image` (blocks until done, a few minutes; follow with `journalctl -fu <name>-image`)
- Update: `git pull`, run `setup-host.sh` again, then `sudo systemctl restart <name>-pool` (this cancels running jobs).
- Add an org: install the GitHub App on it, add it to `orgs` with the next unused `networkIndex`, then run `setup-host.sh` again and restart the pool.

## Troubleshooting

- **VMs have no internet and Docker is installed on the host**: Docker sets the firewall's forwarding policy to drop. With `ufw` active, the setup script adds the forwarding rules it needs; without it, allow the bridges yourself, e.g. `iptables -I DOCKER-USER -i <name>1 -j ACCEPT` and `iptables -I DOCKER-USER -o <name>1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT` for each bridge (`<name>0` and each org's `<name><networkIndex>`).
- **Another firewall (e.g. firewalld)**: allow forwarding from the bridges to the internet and DNS/DHCP from the bridges to the host.
- **Runners don't appear on GitHub**: check `journalctl -u <name>-pool` for GitHub API errors; the App must be installed on the org and have the self-hosted runners permission.

## Trust model

- Job code can use the repository's secrets and anything it can download; it cannot see the host's files, processes, containers or LAN.
- Any job of an org can write to that org's build cache, so a malicious job could poison later builds of the same org. Only run trusted (private) repositories on these runners.
- The GitHub App's private key on the host can register runners in every org it's installed on; keep `secrets/` readable by root only (the setup script sets this).

## Releasing

Bump `VERSION` in a PR, merge it, then run the Release workflow on `main` (Actions → Release → Run workflow). It tags `vX.Y.Z` and publishes the release. Only the release workflow can push version tags.
