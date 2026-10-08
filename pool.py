#!/usr/bin/env python3
import base64
import json
import logging
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

RUNNERS_DIRECTORY = Path(__file__).resolve().parent
CONFIG_DIRECTORY = Path(os.environ.get('GHR_CONFIG_DIR', RUNNERS_DIRECTORY)).resolve()
CONFIG = json.loads((CONFIG_DIRECTORY / 'config.json').read_text())
PRIVATE_KEY_PATH = CONFIG_DIRECTORY / 'secrets' / 'github-app.pem'
NAME = CONFIG['name']
IMAGE_ALIAS = f'{NAME}-runner'
RETRY_DELAY_SECONDS = 30
MAX_RETRY_DELAY_SECONDS = 600
VM_BOOT_TIMEOUT_SECONDS = 180
IMAGE_CHECK_INTERVAL_SECONDS = 300
VM_DELETE_TIMEOUT_SECONDS = 60
JIT_CONFIG_PATH = '/run/jitconfig'


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def create_app_jwt(appId: int, privateKeyPath: Path) -> str:
    now = int(time.time())
    header = _b64url(json.dumps({'alg': 'RS256', 'typ': 'JWT'}).encode())
    payload = _b64url(json.dumps({'iat': now - 60, 'exp': now + 540, 'iss': str(appId)}).encode())
    signingInput = f'{header}.{payload}'
    signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(privateKeyPath)], input=signingInput.encode(), capture_output=True, check=True).stdout
    return f'{signingInput}.{_b64url(signature)}'


def github_request(method: str, path: str, token: str, body: dict | None = None) -> dict | None:
    request = urllib.request.Request(
        url=f'https://api.github.com{path}',
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Accept': 'application/vnd.github+json', 'Authorization': f'Bearer {token}'},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        content = response.read()
    return json.loads(content) if content else None


def get_org_token(orgName: str) -> str:
    appJwt = create_app_jwt(appId=CONFIG['githubAppId'], privateKeyPath=PRIVATE_KEY_PATH)
    installation = github_request('GET', f'/orgs/{orgName}/installation', appJwt)
    return github_request('POST', f'/app/installations/{installation["id"]}/access_tokens', appJwt)['token']


def has_busy_runners() -> bool:
    for orgConfig in CONFIG['orgs']:
        orgName = orgConfig['name']
        runners = github_request('GET', f'/orgs/{orgName}/actions/runners?per_page=100', get_org_token(orgName))['runners']
        if any(runner['busy'] and runner['name'].startswith(f'{NAME}-{orgName}-job-') for runner in runners):
            return True
    return False


def incus(*args: str) -> str:
    result = subprocess.run(['incus', *args], stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f'incus {args[0]} failed: {result.stderr.strip()}')
    return result.stdout


def delete_vm(vmName: str) -> None:
    result = subprocess.run(['incus', 'delete', '--force', vmName], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=VM_DELETE_TIMEOUT_SECONDS)
    # Job VMs are ephemeral, so they are often already gone.
    if result.returncode != 0 and 'not found' not in result.stderr.lower():
        raise RuntimeError(f'incus delete {vmName} failed: {result.stderr.strip()}')


class OrgPool:
    def __init__(self, orgConfig: dict, stopEvent: threading.Event) -> None:
        self.orgName = orgConfig['name']
        self.jobVmCount = orgConfig['jobVmCount']
        self.cacheAddress = f'{CONFIG["subnetPrefix"]}.{orgConfig["networkIndex"]}.2'
        self.jobProfile = f'{NAME}-{self.orgName}-job'
        # NOTE(krishan711): the name also prefixes the GitHub runners, so machines serving the same org must use different names or they delete each other's runners
        self.vmPrefix = f'{NAME}-{self.orgName}-job-'
        self.stopEvent = stopEvent
        self.retiredVmNames: set[str] = set()

    def delete_vms(self) -> None:
        for instance in json.loads(incus('list', '--format', 'json')):
            if instance['name'].startswith(self.vmPrefix):
                try:
                    delete_vm(instance['name'])
                except Exception:
                    logging.exception(f'[{instance["name"]}] could not delete')

    def delete_github_runners(self) -> None:
        token = get_org_token(self.orgName)
        runners = github_request('GET', f'/orgs/{self.orgName}/actions/runners?per_page=100', token)['runners']
        for runner in runners:
            if runner['name'].startswith(self.vmPrefix):
                try:
                    github_request('DELETE', f'/orgs/{self.orgName}/actions/runners/{runner["id"]}', token)
                except Exception:
                    logging.exception(f'Failed to delete GitHub runner {runner["name"]}')

    def retire_outdated_idle_vms(self) -> None:
        currentImage = json.loads(incus('query', f'/1.0/images/aliases/{IMAGE_ALIAS}'))['target']
        # NOTE(krishan711): incus lists a VM with no config while it is being created or deleted
        outdatedVmNames = {instance['name'] for instance in json.loads(incus('list', '--format', 'json')) if instance['name'].startswith(self.vmPrefix) and instance['config'] and instance['config'].get('volatile.base_image') != currentImage}
        if not outdatedVmNames:
            return
        token = get_org_token(self.orgName)
        for runner in github_request('GET', f'/orgs/{self.orgName}/actions/runners?per_page=100', token)['runners']:
            if runner['name'] not in outdatedVmNames or runner['busy']:
                continue
            self.retiredVmNames.add(runner['name'])
            try:
                # GitHub refuses to remove a runner that is running a job, so this can't kill a job that started after the busy check.
                github_request('DELETE', f'/orgs/{self.orgName}/actions/runners/{runner["id"]}', token)
            except Exception:
                self.retiredVmNames.discard(runner['name'])
                continue
            logging.info(f'[{runner["name"]}] replacing: built from an old image')
            delete_vm(runner['name'])

    def run_slot(self) -> None:
        failureCount = 0
        while not self.stopEvent.is_set():
            vmName = f'{self.vmPrefix}{uuid.uuid4().hex[:8]}'
            try:
                self._run_job_vm(vmName=vmName)
                failureCount = 0
            except Exception:
                if not self.stopEvent.is_set():
                    failureCount += 1
                    retryDelay = min(RETRY_DELAY_SECONDS * 2 ** (failureCount - 1), MAX_RETRY_DELAY_SECONDS)
                    logging.exception(f'[{vmName}] failed, retrying in {retryDelay}s')
                    self.stopEvent.wait(retryDelay)
            finally:
                self.retiredVmNames.discard(vmName)
                self._delete_vm_before_replacing(vmName=vmName)

    def _delete_vm_before_replacing(self, vmName: str) -> None:
        while True:
            try:
                delete_vm(vmName)
                return
            except Exception:
                logging.exception(f'[{vmName}] could not delete, retrying in {RETRY_DELAY_SECONDS}s')
            if self.stopEvent.wait(RETRY_DELAY_SECONDS):
                return

    def _wait_for_vm(self, vmName: str) -> None:
        deadline = time.monotonic() + VM_BOOT_TIMEOUT_SECONDS
        while subprocess.run(['incus', 'exec', vmName, '--', 'true'], stdin=subprocess.DEVNULL, capture_output=True).returncode != 0:
            if self.stopEvent.is_set() or time.monotonic() > deadline:
                raise TimeoutError(f'{vmName} did not boot within {VM_BOOT_TIMEOUT_SECONDS}s')
            time.sleep(2)
        subprocess.run(['incus', 'exec', vmName, '--', 'cloud-init', 'status', '--wait'], stdin=subprocess.DEVNULL, capture_output=True)

    def _run_job_vm(self, vmName: str) -> None:
        # Register first: if GitHub can't register runners, fail before spending a VM boot on it.
        jitConfig = github_request('POST', f'/orgs/{self.orgName}/actions/runners/generate-jitconfig', get_org_token(self.orgName), {
            'name': vmName,
            'runner_group_id': CONFIG['runnerGroupId'],
            'labels': CONFIG['runnerLabels'],
        })
        try:
            logging.info(f'[{vmName}] launching')
            incus('launch', IMAGE_ALIAS, vmName, '--vm', '--ephemeral', '--profile', self.jobProfile)
            self._wait_for_vm(vmName=vmName)
            qemuPid = json.loads(incus('query', f'/1.0/instances/{vmName}/state'))['pid']
            # When VM memory runs out the kernel kills the biggest process, which would be the long-lived cache VM; make it a throwaway job VM instead.
            # Only after boot: Incus replaces the first QEMU process a few seconds after launch.
            Path(f'/proc/{qemuPid}/oom_score_adj').write_text('1000')
            incus('exec', vmName, '--', 'sh', '-c', f'echo "{self.cacheAddress} buildkit" >> /etc/hosts')
            subprocess.run(['incus', 'exec', vmName, '--', 'systemd-run', '--unit', 'prepull-images', '/usr/local/bin/prepull-images'], stdin=subprocess.DEVNULL, capture_output=True)
            if self.stopEvent.is_set():
                return
            logging.info(f'[{vmName}] waiting for a job')
            # The JIT config holds the runner's credentials, so it goes in through stdin rather than the host's process arguments.
            subprocess.run(['incus', 'exec', vmName, '--', 'sh', '-c', f'umask 077 && cat > {JIT_CONFIG_PATH}'], input=jitConfig['encoded_jit_config'], capture_output=True, text=True, check=True)
            # Read here rather than in a shell under `sudo -i`, which would expand $jitConfig in the runner's login shell first.
            result = subprocess.run(['incus', 'exec', vmName, '--', 'sh', '-c', f'jitConfig="$(cat {JIT_CONFIG_PATH})" && rm {JIT_CONFIG_PATH} && exec sudo -iu runner /home/runner/actions-runner/run.sh --jitconfig "$jitConfig"'], stdin=subprocess.DEVNULL)
            if result.returncode != 0 and not self.stopEvent.is_set() and vmName not in self.retiredVmNames:
                raise RuntimeError(f'runner exited with code {result.returncode}')
            logging.info(f'[{vmName}] finished')
        finally:
            self._delete_github_runner(runnerId=jitConfig['runner']['id'])

    def _delete_github_runner(self, runnerId: int) -> None:
        # Ephemeral runners remove themselves after a job, so this only matters when the VM never ran one; GitHub refuses to delete a busy runner.
        try:
            github_request('DELETE', f'/orgs/{self.orgName}/actions/runners/{runnerId}', get_org_token(self.orgName))
        except Exception as error:
            if not (isinstance(error, urllib.error.HTTPError) and error.code == 404):
                logging.warning(f'Failed to delete GitHub runner {runnerId}: {error}')


def main() -> None:
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    if sys.argv[1:] == ['--check-busy-runners']:
        raise SystemExit(1 if has_busy_runners() else 0)
    if not CONFIG.get('githubAppId'):
        raise SystemExit(f'Set githubAppId in {CONFIG_DIRECTORY / "config.json"}')
    stopEvent = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopEvent.set())
    signal.signal(signal.SIGINT, lambda *_: stopEvent.set())
    pools = [OrgPool(orgConfig=orgConfig, stopEvent=stopEvent) for orgConfig in CONFIG['orgs']]
    for pool in pools:
        pool.delete_vms()
        pool.delete_github_runners()
    threads = [threading.Thread(target=pool.run_slot, daemon=True) for pool in pools for _ in range(pool.jobVmCount)]
    for thread in threads:
        thread.start()
    logging.info(f'Started {len(threads)} runner slots for {", ".join(pool.orgName for pool in pools)}')
    while not stopEvent.wait(IMAGE_CHECK_INTERVAL_SECONDS):
        for pool in pools:
            try:
                pool.retire_outdated_idle_vms()
            except Exception:
                logging.exception(f'Failed to replace outdated VMs for {pool.orgName}')
    logging.info('Stopping: deleting job VMs')
    for pool in pools:
        pool.delete_vms()
    for thread in threads:
        thread.join(timeout=60)
    for pool in pools:
        pool.delete_vms()
        pool.delete_github_runners()


if __name__ == '__main__':
    main()
