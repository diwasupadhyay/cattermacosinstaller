"""Remove local authentication state without revoking device signing certificates."""
from types import SimpleNamespace
import time
import re
from contextlib import contextmanager


class AuthenticationStageError(RuntimeError):
    """Contains only locally defined stage text and a numeric status."""


@contextmanager
def authentication_stages(gsa):
    """Expose only the failing stage and numeric status, never response bodies."""
    names = {
        '_submit_trusted': 'verification-code submission',
        '_submit_sms': 'verification-code submission',
        '_authenticate_once': 'Apple account authentication',
        '_fetch_app_token': 'developer-token exchange',
    }
    originals = {}
    def wrap(function, stage):
        def call(*args, **kwargs):
            try:
                return function(*args, **kwargs)
            except Exception as error:
                match = re.search(r'Apple error (-?\d{1,8})(?=:)', str(error))
                http = re.search(r'HTTP (\d{3})\b', str(error))
                detail = ('Apple error ' + match[1]) if match else ('HTTP ' + http[1]) if http else 'request failed'
                raise AuthenticationStageError(f'Sign-in stopped during {stage} ({detail}). '
                                   'No sign-in was confirmed. Keep the installed app; do not revoke certificates.') from None
        return call
    try:
        for name, stage in names.items():
            originals[name] = getattr(gsa, name)
            setattr(gsa, name, wrap(originals[name], stage))
        yield
    finally:
        for name, original in originals.items():
            setattr(gsa, name, original)


class MemoryFile:
    """Minimal file API used by the pinned signing engine's session storage."""
    def __init__(self, store, name):
        self.store, self.name = store, name

    def exists(self):
        return self.name in self.store

    def write_text(self, text, encoding='utf-8'):
        self.store[self.name] = (text, time.time())
        return len(text)

    def read_text(self, encoding='utf-8'):
        if not self.exists():
            raise FileNotFoundError('No in-memory session')
        return self.store[self.name][0]

    def unlink(self, missing_ok=False):
        if not missing_ok and not self.exists():
            raise FileNotFoundError('No in-memory session')
        self.store.pop(self.name, None)

    def stat(self):
        if not self.exists():
            raise FileNotFoundError('No in-memory session')
        return SimpleNamespace(st_mtime=self.store[self.name][1])


class MemoryAccounts:
    def __init__(self, store):
        self.store = store

    def glob(self, pattern):
        if pattern != '*.json':
            raise RuntimeError('Unsupported session enumeration')
        return [MemoryFile(self.store, name) for name in list(self.store)
                if name.startswith('accounts/')]


def use_memory_sessions(gsa, paths):
    """Remove legacy disk sessions before exposing an empty per-process store.

    This intercepts only account/challenge paths, not signing keys or pairing.
    The actual Apple authentication protocol remains upstream's implementation.
    """
    sign_out(gsa, paths)
    store = {}
    paths.pending_2fa_file = lambda: MemoryFile(store, 'pending')
    paths.active_account_file = lambda: MemoryFile(store, 'active')
    paths.legacy_account_file = lambda: MemoryFile(store, 'legacy')
    paths.account_file = lambda email: MemoryFile(store, 'accounts/' + paths.account_slug(email))
    paths.accounts_dir = lambda: MemoryAccounts(store)
    gsa._catter_clear_session = store.clear
    # Do not retain authentication-response diagnostics on disk.
    gsa._trace = lambda *args, **kwargs: None


def sign_out(gsa, paths):
    clear = getattr(gsa, '_catter_clear_session', None)
    if clear is not None:
        clear()
    session = paths.session_dir().resolve()
    expected = paths.data_dir().resolve() / 'session'
    if session != expected or paths.session_dir().is_symlink() or paths.session_dir().is_junction():
        raise RuntimeError('Unexpected session directory. Sign-out stopped without deleting files.')
    # Validate the complete deletion set before touching anything, including legacy
    # or malformed account files that an account-listing API might ignore.
    entries = list(session.rglob('*'))
    if any(p.is_symlink() or p.is_junction() or not p.resolve().is_relative_to(session) for p in entries):
        raise RuntimeError('Unexpected link in session storage. Sign-out stopped.')
    files = [p for p in entries if p.is_file()]
    for path in files:
        path.unlink()
    if gsa.status().get('authenticated') or any(p.is_file() for p in session.rglob('*')):
        raise RuntimeError('Local session removal could not be verified.')
