"""Opt-in Apple token cache. Passwords and pending 2FA are never persisted."""
import hashlib
import json
import time
from pathlib import Path

from cryptography.fernet import Fernet
from invitation_store import vault

SERVICE = 'Catter Setup Apple Session'
MAX_AGE = 7 * 24 * 60 * 60
FIELDS = {'email', 'adsid', 'GsIdmsToken', 'auth_token', 'auth_token_expiry', 'team_id'}


class SessionVault:
    def __init__(self, folder):
        self.folder = Path(folder)
        self.file = self.folder / 'apple-session.enc'
        self.identity = hashlib.sha256(str(self.folder.resolve()).encode()).hexdigest()

    def forget(self):
        # Ciphertext deletion prevents reuse even if the OS vault is locked.
        self.file.unlink(missing_ok=True)
        try:
            vault().delete_password(SERVICE, self.identity)
        except Exception:
            pass

    def save(self, account, *, expires=None, remote=False):
        now = time.time()
        expires = min(expires if expires is not None else now + MAX_AGE, now + MAX_AGE)
        if expires <= now:
            self.forget()
            return None
        data = {k: v for k, v in account.items() if k in FIELDS}
        if not data.get('email') or not data.get('auth_token'):
            raise ValueError('No reusable Apple developer session')
        value = {'account': data, 'created': now, 'expires': expires, 'remote': bool(remote)}
        key = Fernet.generate_key()
        encrypted = Fernet(key).encrypt(json.dumps(value).encode())
        if self.file.is_symlink():
            raise RuntimeError('Linked session storage is not allowed')
        vault().set_password(SERVICE, self.identity, key.decode('ascii'))
        try:
            self.file.write_bytes(encrypted)
            self.file.chmod(0o600)
        except Exception:
            self.forget()
            raise RuntimeError('Session could not be saved securely') from None
        return expires

    def load(self):
        if not self.file.exists():
            return None
        try:
            if self.file.is_symlink() or self.file.stat().st_size > 131072:
                raise ValueError('Invalid session file')
            key = vault().get_password(SERVICE, self.identity)
            if not key:
                raise ValueError('Missing vault key')
            data = json.loads(Fernet(key.encode('ascii')).decrypt(self.file.read_bytes()))
            now = time.time()
            if not data['created'] <= now < data['expires'] <= data['created'] + MAX_AGE:
                raise ValueError('Expired session')
            account = data['account']
            if not isinstance(account, dict) or set(account) - FIELDS or not account.get('auth_token') or not account.get('email'):
                raise ValueError('Invalid account')
            return data
        except Exception:
            self.forget()
            return None
