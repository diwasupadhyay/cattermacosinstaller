"""Prepare one USB iPhone. Never sets location or handles Apple account credentials."""
import argparse
import asyncio
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import uuid
import json
import re

if __name__ == '__main__':
    print('Loading iPhone preparation tools...', flush=True)

from pymobiledevice3 import usbmux
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService
from pymobiledevice3.services.installation_proxy import InstallationProxyService

BASE_ID = 'com.diwasupadhyay.ghostlyios'
REMOTE_DIRECTORY = '/Library/Application Support/PrivatePairing'
REMOTE_FILE = REMOTE_DIRECTORY + '/remote-pairing.plist'


async def prepare_classic_transport(device, container, serial):
    # Use only the record of the authenticated, selected USB session. Never
    # search other devices' records or print certificate/key material.
    record = dict(device.pair_record or {})
    for key in ('DeviceCertificate', 'HostCertificate', 'HostPrivateKey',
                'RootCertificate', 'RootPrivateKey'):
        if not isinstance(record.get(key), bytes) or not record[key]:
            raise RuntimeError('USB pairing record is incomplete; classic transport was not prepared.')
    for key in ('HostID', 'SystemBUID', 'WiFiMACAddress'):
        if not isinstance(record.get(key), str) or not record[key]:
            raise RuntimeError('USB pairing identity is incomplete; classic transport was not prepared.')
    if record.get('UDID') and record['UDID'] != serial:
        raise RuntimeError('USB pairing identity does not match the selected iPhone.')
    record['UDID'] = serial
    data = plistlib.dumps(record)
    domain = 'com.apple.mobile.wireless_lockdown'
    await device.set_value(True, domain=domain, key='EnableWifiDebugging')
    if await device.get_value(domain=domain, key='EnableWifiDebugging') is not True:
        raise RuntimeError('iPhone did not confirm network developer access. Classic transport was not transferred.')
    await container.makedirs(REMOTE_DIRECTORY)
    temporary = REMOTE_DIRECTORY + '/classic-transfer.tmp'
    destination = REMOTE_DIRECTORY + '/lockdown-pairing.plist'
    await container.set_file_contents(temporary, data)
    if await container.get_file_contents(temporary) != data:
        raise RuntimeError('Classic pairing transfer verification failed; existing record retained.')
    await container.rename(temporary, destination)
    if await container.get_file_contents(destination) != data:
        raise RuntimeError('Classic pairing final verification failed.')
    print('Classic pairing transferred. Network developer access enabled; cellular operation still needs testing.', flush=True)


def select_app(apps):
    matches = [key for key in apps if key == BASE_ID or key.startswith(BASE_ID + '.')]
    if len(matches) != 1:
        raise RuntimeError('Install one copy of Catter before preparation. '
                           'If multiple copies are installed, keep only the intended copy.')
    return matches[0]


def validate_record(data):
    if not 0 < len(data) <= 1_048_576:
        raise ValueError('Invalid pairing-file size.')
    record = plistlib.loads(data)
    for key in ('public_key', 'private_key'):
        if not isinstance(record.get(key), bytes) or len(record[key]) != 32:
            raise ValueError('Expected a remote-pairing record, not an older lockdown record.')
    if not isinstance(record.get('identifier'), str) or not record['identifier']:
        raise ValueError('Pairing identity is missing.')


def native(arguments, timeout=90):
    # Native tools may dump metadata: keep output private, expose only success/failure summaries.
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout,
                            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    if result.returncode != 0:
        raise RuntimeError('Pairing utility failed. Keep the iPhone unlocked and trusted, then retry.')
    return result.stdout + result.stderr


async def create_pairing(container, args, serial, record_path):
    candidate = args.private_dir / ('new-pairing-' + uuid.uuid4().hex + '.plist')
    print('Creating a new pairing. Keep the iPhone unlocked and accept any system prompt.', flush=True)
    await asyncio.to_thread(native, [str(args.native), '--udid', serial,
        'rppairing', 'pair', 'GhostlyIOS', str(candidate)])
    if not candidate.exists():
        raise RuntimeError('The phone did not produce a pairing file. Unlock it, accept Trust, and retry.')
    data = candidate.read_bytes()
    validate_record(data)
    output = await asyncio.to_thread(native, [str(args.native), '--udid', serial,
        'remotepairing_lockdown', 'verify', str(candidate), 'GhostlyIOS'])
    if 'the device recognizes this pairing record' not in output:
        raise RuntimeError('The new pairing was not verified. Nothing was transferred into the app.')
    candidate.replace(record_path)
    await container.makedirs(REMOTE_DIRECTORY)
    temporary = REMOTE_DIRECTORY + '/setup-transfer.tmp'
    await container.set_file_contents(temporary, data)
    await container.rename(temporary, REMOTE_FILE)
    if await container.get_file_contents(REMOTE_FILE) != data:
        raise RuntimeError('Pairing transfer verification failed.')
    print('New pairing verified and transferred directly into the app.', flush=True)


async def checked_step(awaitable, description, timeout=30):
    print(description, flush=True)
    try:
        return await asyncio.wait_for(awaitable, timeout)
    except asyncio.TimeoutError:
        raise RuntimeError(description + ' timed out. Unlock the iPhone, check the USB cable, '
                           'accept Trust if shown, and retry Continue preparation. '
                           'If Developer Mode is off, enable it in Settings > Privacy & Security, '
                           'restart and confirm Turn On first.') from None


async def prepare(args):
    devices = [device for device in await checked_step(usbmux.list_devices(), 'Looking for your USB iPhone...') if device.is_usb]
    if len(devices) != 1:
        raise RuntimeError('Connect exactly one iPhone by USB, unlock it, and accept Trust.')
    serial = devices[0].serial
    if getattr(args, 'udid', None) and serial != args.udid:
        raise RuntimeError('The connected iPhone changed. Reconnect the phone selected for installation.')
    async with await checked_step(create_using_usbmux(serial=serial), 'Connecting to your unlocked iPhone. Accept Trust if shown...', 45) as device:
        if not await checked_step(device.get_developer_mode_status(), 'Checking Developer Mode...'):
            raise RuntimeError('Enable Settings > Privacy & Security > Developer Mode, restart, then run this again.')
        async with InstallationProxyService(device) as service:
            apps = await service.get_apps(application_type='User')
        bundle = select_app(apps)
        print('Detected iOS', device.product_version, 'with Developer Mode enabled.', flush=True)
        print('Catter build:', apps[bundle].get('CFBundleVersion', 'unknown'), flush=True)
        async with await HouseArrestService.create(device, bundle) as container:
            preferences = '/Library/Preferences/' + bundle + '.plist'
            if await container.exists(preferences):
                prefs = plistlib.loads(await container.get_file_contents(preferences))
                if prefs.get('simulationUnresolved'):
                    raise RuntimeError('Restore in Catter and confirm your real location before preparing it again.')
            existing = await container.get_file_contents(REMOTE_FILE) if await container.exists(REMOTE_FILE) else None
            if existing:
                validate_record(existing)
            print('Pairing:', 'already installed' if existing else 'not installed', flush=True)
            if args.check_only:
                print('Checks passed. No pairing, transfer, or image-mount changes were made.')
                return
            access_binding = getattr(args, 'access_binding', None)
            if access_binding:
                data = access_binding.read_bytes()
                binding = json.loads(data)
                if len(data) > 2048 or not isinstance(binding.get('id'), str) or not re.fullmatch(r'[a-f0-9]{64}', binding.get('proof', '')):
                    raise RuntimeError('Invalid setup authorization. Reopen the installer and verify your invitation again.')
                await container.makedirs(REMOTE_DIRECTORY)
                destination = REMOTE_DIRECTORY + '/access-binding.json'
                await container.set_file_contents(destination + '.tmp', data)
                await container.rename(destination + '.tmp', destination)
                if await container.get_file_contents(destination) != data:
                    raise RuntimeError('Setup authorization transfer was not verified. Retry preparation.')
                print('Invitation authorization transferred to this iPhone.', flush=True)
            renewal_bootstrap = getattr(args, 'renewal_bootstrap', None)
            if renewal_bootstrap:
                data = renewal_bootstrap.read_bytes()
                handoff = json.loads(data)
                if len(data) > 65536 or handoff.get('udid') != serial or handoff.get('bundleID') != bundle or not isinstance(handoff.get('p12'), str):
                    raise RuntimeError('Renewal setup does not match the selected iPhone and app. Nothing was transferred.')
                await container.makedirs(REMOTE_DIRECTORY)
                destination = REMOTE_DIRECTORY + '/renewal-bootstrap.json'
                await container.set_file_contents(destination + '.tmp', data)
                await container.rename(destination + '.tmp', destination)
                if await container.get_file_contents(destination) != data:
                    raise RuntimeError('Renewal setup transfer was not verified. Retry installation.')
                print('Renewal signing identity transferred privately. Open Catter to finish Keychain setup.', flush=True)
            record_path = args.private_dir / 'remote-pairing.plist'
            if existing:
                record_path.write_bytes(existing)
                output = await asyncio.to_thread(native, [str(args.native), '--udid', serial,
                    'remotepairing_lockdown', 'verify', str(record_path), 'GhostlyIOS'])
                if 'the device recognizes this pairing record' not in output:
                    raise RuntimeError('Stored pairing was not verified. Keep it intact; use app Setup to remove it only after restoring.')
                print('Existing pairing verified; no replacement needed.', flush=True)
            elif record_path.exists():
                # App deletion removes its container. Reuse the private Windows
                # backup only after the attached phone verifies this exact identity.
                data = record_path.read_bytes()
                validate_record(data)
                output = await asyncio.to_thread(native, [str(args.native), '--udid', serial,
                    'remotepairing_lockdown', 'verify', str(record_path), 'GhostlyIOS'])
                if 'the device recognizes this pairing record' not in output:
                    if not getattr(args, 'replace_unrecognized_backup', False):
                        raise RuntimeError('PAIRING_BACKUP_REJECTED: The phone did not recognize the Windows backup. A new pairing is needed; no file was transferred.')
                    record_path.replace(args.private_dir / ('rejected-pairing-' + uuid.uuid4().hex + '.plist'))
                    await create_pairing(container, args, serial, record_path)
                else:
                    await container.makedirs(REMOTE_DIRECTORY)
                    temporary = REMOTE_DIRECTORY + '/setup-transfer.tmp'
                    await container.set_file_contents(temporary, data)
                    await container.rename(temporary, REMOTE_FILE)
                    if await container.get_file_contents(REMOTE_FILE) != data:
                        raise RuntimeError('Pairing backup transfer verification failed.')
                    print('Existing Windows pairing backup verified and restored into the app.', flush=True)
            else:
                await create_pairing(container, args, serial, record_path)
            if str(apps[bundle].get('CFBundleVersion', '')) == '13':
                print('Preparing experimental CoreDeviceProxy access for this iPhone...', flush=True)
                await prepare_classic_transport(device, container, serial)
    print('Preparing the developer image. First download can take several minutes...', flush=True)
    environment = dict(os.environ, PYMOBILEDEVICE3_UDID=serial)
    process = await asyncio.create_subprocess_exec(sys.executable, '-m', 'pymobiledevice3',
        'mounter', 'auto-mount', env=environment,
        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    try:
        result = await asyncio.wait_for(process.wait(), 600)
    except asyncio.TimeoutError:
        process.kill()
        await process.wait()
        raise RuntimeError('Developer-image preparation timed out. Its state is unverified; rerun preparation.')
    if result != 0:
        raise RuntimeError('Developer image preparation failed. Pairing is retained; fix the reported image/tunnel error and retry.')
    print('Preparation completed. Reopen Catter, open VPN, and check the connection.')
    print('No location was changed. Test new coordinates after unplugging USB.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', required=True, type=Path)
    parser.add_argument('--private-dir', required=True, type=Path)
    parser.add_argument('--check-only', action='store_true')
    parser.add_argument('--replace-unrecognized-backup', action='store_true', help='Create fresh pairing only if the app has no record and the local backup is rejected')
    parser.add_argument('--access-binding', type=Path, help='Private installer authorization to transfer to the selected iPhone')
    parser.add_argument('--renewal-bootstrap', type=Path, help='Explicitly approved private renewal identity handoff')
    parser.add_argument('--udid', help='Require this exact USB device throughout preparation')
    args = parser.parse_args()
    args.private_dir.mkdir(parents=True, exist_ok=True)
    try:
        asyncio.run(asyncio.wait_for(prepare(args), 900))
    except Exception as error:
        print('Preparation stopped:', str(error) or 'Preparation timed out. Keep the app installed, unlock the iPhone and retry Continue preparation.', file=sys.stderr, flush=True)
        sys.exit(1)
