"""Store invitation codes in the OS credential vault, never in plaintext files."""
import re
import sys

SERVICE = 'Catter Setup Invitation'


def vault():
    if sys.platform == 'darwin':
        from keyring.backends.macOS import Keyring
        return Keyring()
    if sys.platform == 'win32':
        from keyring.backends.Windows import WinVaultKeyring
        return WinVaultKeyring()
    raise RuntimeError('No supported credential vault')


def load(device):
    try:
        code = vault().get_password(SERVICE, device)
        return code if isinstance(code, str) and re.fullmatch(r'[a-f0-9]{48}', code) else None
    except Exception:
        return None


def save(device, code):
    if not re.fullmatch(r'[a-f0-9]{48}', code):
        return False
    try:
        vault().set_password(SERVICE, device, code)
        return True
    except Exception:
        return False


def forget(device):
    try:
        vault().delete_password(SERVICE, device)
    except Exception:
        pass
