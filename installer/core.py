"""Catter-only installation policy. No Apple credentials are handled here."""
from pathlib import Path, PurePosixPath
import plistlib
import zipfile
import stat
import hashlib


def file_digest(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

BASE_ID = 'com.diwasupadhyay.ghostlyios'


def inspect_ipa(path):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 50_000:
            raise ValueError('IPA contains too many files.')
        if sum(item.file_size for item in entries) > 1_073_741_824:
            raise ValueError('IPA is unexpectedly large for Catter.')
        seen = set()
        for item in entries:
            name = PurePosixPath(item.filename)
            if name.is_absolute() or '..' in name.parts or chr(92) in item.filename or ':' in item.filename:
                raise ValueError('Unsafe path in IPA.')
            if any(part.endswith((' ', '.')) or part.split('.')[0].upper() in
                   {'CON', 'PRN', 'AUX', 'NUL', *(f'COM{i}' for i in range(1, 10)),
                    *(f'LPT{i}' for i in range(1, 10))} for part in name.parts):
                raise ValueError('IPA contains an unsafe Windows filename.')
            normalized = str(name).casefold()
            if normalized in seen:
                raise ValueError('IPA contains duplicate or ambiguous file paths.')
            seen.add(normalized)
            mode = item.external_attr >> 16
            if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                raise ValueError('IPA contains unsupported links or special files.')
            if item.flag_bits & 1:
                raise ValueError('Encrypted IPA archives are not supported.')
        manifests = [item for item in entries if item.filename.startswith('Payload/')
                     and item.filename.count('/') == 2 and item.filename.endswith('.app/Info.plist')]
        if len(manifests) != 1 or manifests[0].file_size > 1_048_576:
            raise ValueError('Choose an IPA containing exactly one Catter app.')
        info = plistlib.loads(archive.read(manifests[0]))
        if not isinstance(info, dict):
            raise ValueError('Invalid app manifest.')
        identity = info.get('CFBundleIdentifier', '')
        if not isinstance(identity, str) or (identity != BASE_ID and not identity.startswith(BASE_ID + '.')):
            raise ValueError('This installer accepts Catter IPAs only.')
        return {key: info.get(key, '') for key in ('CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString')}


def one_usb_device(devices):
    serials = {item.get('serial') for item in devices
               if str(item.get('connection_type', '')).upper() == 'USB' and item.get('serial')}
    if len(serials) != 1:
        raise RuntimeError('Connect exactly one iPhone by USB, unlock it and accept Trust.')
    return serials.pop()


def check_target(expected, devices):
    actual = one_usb_device(devices)
    if actual != expected:
        raise RuntimeError('The connected iPhone changed. Reconnect the phone selected for installation.')
    return actual
