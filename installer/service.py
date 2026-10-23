"""Catter installer service; uses pinned iPASide engine for Apple signing.

Passwords and 2FA codes stay in process memory and never enter subprocess args.
No scheduler or automatic renewal is installed.
"""
import hashlib
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import tempfile
import shutil
import time

from core import inspect_ipa, one_usb_device, check_target, file_digest
from certificates import certificate_recovery
from account_security import sign_out, use_memory_sessions, authentication_stages, AuthenticationStageError
from branding import SIGNING_NAME, storage_namespace

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'scripts'))


def protect_directory(path):
    if path.is_symlink():
        raise RuntimeError('Private setup storage must not be a symbolic link.')
    path.mkdir(parents=True, exist_ok=True)
    if sys.platform == 'darwin':
        path.chmod(0o700)
        return
    identity = subprocess.run(['whoami', '/user', '/fo', 'csv', '/nh'], capture_output=True,
                              text=True, check=True, creationflags=subprocess.CREATE_NO_WINDOW)
    import csv
    sid = next(csv.reader([identity.stdout.strip()]))[-1]
    if not sid.startswith('S-1-'):
        raise RuntimeError('Could not identify this Windows account.')
    subprocess.run(['icacls', str(path), '/inheritance:r', '/grant:r',
                    f'*{sid}:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F'],
                   capture_output=True, check=True, creationflags=subprocess.CREATE_NO_WINDOW)


def preparation_output(child, emit, startup_timeout=30, total_timeout=930, heartbeat=15):
    """Do not let a silent child pipe block the service worker indefinitely."""
    output = queue.Queue()
    def read():
        try:
            for line in child.stdout:
                output.put(line)
        finally:
            output.put(None)
    threading.Thread(target=read, daemon=True).start()
    started = time.monotonic()
    next_notice = started + heartbeat
    received = False
    try:
        while True:
            now = time.monotonic()
            if now - started > total_timeout or (not received and now - started > startup_timeout):
                raise RuntimeError('Preparation helper did not respond in time. No completion was confirmed. '
                                   'Close setup, reconnect the unlocked iPhone, then retry Continue preparation.')
            try:
                line = output.get(timeout=min(0.25, startup_timeout))
            except queue.Empty:
                if now >= next_notice:
                    emit('Waiting for iPhone preparation' if received else 'Starting preparation helper; waiting for its first response...')
                    next_notice = now + heartbeat
                continue
            if line is None:
                return
            received = True
            next_notice = time.monotonic() + heartbeat
            yield line
    except BaseException:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=10)
        raise


class InstallerService:
    def __init__(self):
        self.events = queue.Queue()
        self.working = False
        self.target = None
        self.ipa = None
        self.ipa_digest = None
        self.access_code = None
        self.mac_metadata = None
        self.remote_metadata_enabled = False
        if sys.platform == 'darwin':
            os.umask(0o077)
            # Set before the engine resolves any storage; never write inside .app.
            os.environ.setdefault('LOCALAPPDATA', str(Path.home() / 'Library' / 'Application Support'))
        namespace = storage_namespace(os.environ['LOCALAPPDATA'])
        self.private = Path(os.environ['LOCALAPPDATA']) / namespace
        protect_directory(self.private)
        from ipaside_engine import paths, provision, gsa
        paths.APP_NAME = namespace
        provision.CERTIFICATE_MACHINE_NAME = SIGNING_NAME
        use_memory_sessions(gsa, paths)
        if sys.platform == 'darwin':
            from local_macos_metadata import enable
            self.mac_metadata = enable(gsa)

    def work(self, function):
        if self.working:
            raise RuntimeError('Wait for the current operation to finish.')
        self.working = True
        def run():
            try:
                function()
            except Exception as error:
                self.events.put(('error', str(error)))
            finally:
                self.events.put(('finished', None))
        threading.Thread(target=run, daemon=True).start()

    def select_ipa(self, path):
        self.ipa = None
        self.ipa_digest = None
        info = inspect_ipa(path)
        digest = file_digest(path)
        self.ipa, self.ipa_digest = path, digest
        return info

    def close(self):
        self.access_code = None
        from ipaside_engine import gsa, paths
        sign_out(gsa, paths)

    def choose_certificate(self, certificates):
        answer, ready = [], threading.Event()
        self.events.put(('certificates', (certificates, answer, ready)))
        ready.wait()
        return answer[0]

    def ask_phone_step(self, title, text):
        answer, ready = [], threading.Event()
        self.events.put(('phone', (title, text, answer, ready)))
        ready.wait()
        return answer[0]

    def emit(self, text):
        self.events.put(('status', str(text)))

    def require_access(self, interactive=True):
        from access import authorize, InvitationRejected
        from invitation_store import load, save, forget
        from ipaside_engine import device
        target = one_usb_device(device.list_devices())
        identity = hashlib.sha256(('catter-usb-v1:' + target).encode()).hexdigest()
        if not self.access_code:
            self.access_code = load(identity)
        if not self.access_code and not interactive:
            return
        if not self.access_code:
            answer, ready = [], threading.Event()
            self.events.put(('access', (
                'Connect the iPhone you want to authorize by USB, then paste your invitation code. '
                'This code will be assigned to that iPhone. Its access period begins at first use; the owner sets its duration. '
                'You will use the same code in Catter Settings on your iPhone. '
                'This is separate from your Apple verification code.', answer, ready)))
            ready.wait()
            value = answer.pop() if answer else None
            if not isinstance(value, str) or not value.strip():
                raise RuntimeError('Activation cancelled. No installation changes were made.')
            self.access_code = value.strip().lower()
        try:
            from ipaside_engine import device
            check_target(target, device.list_devices())
            if self.target is not None:
                check_target(self.target, device.list_devices())
            authorization = authorize(self.access_code, identity)
            import json, re
            proof = authorization.get('setupProof', '')
            if not isinstance(proof, str) or not re.fullmatch(r'[a-f0-9]{64}', proof):
                raise RuntimeError('The access service did not provide preparation authorization. Update setup and retry.')
            folder = self.private / 'devices' / hashlib.sha256(target.encode()).hexdigest()[:24]
            folder.mkdir(parents=True, exist_ok=True)
            (folder / 'access-binding.json').write_text(json.dumps({'id': authorization['id'], 'proof': proof}), encoding='utf-8')
            self.target = target
        except InvitationRejected:
            forget(identity)
            self.access_code = None
            raise
        except Exception:
            self.access_code = None
            raise
        if save(identity, self.access_code):
            self.emit('Invitation verified and remembered securely for this iPhone.')
        else:
            self.emit('Invitation verified. Secure storage was unavailable; enter it again next time.')

    def restore_access(self):
        try:
            self.require_access(interactive=False)
        except Exception as error:
            from access import InvitationRejected
            self.access_code = None
            if isinstance(error, InvitationRejected):
                self.emit('Your invitation expired, was revoked, or is no longer valid for this iPhone. Enter a valid invitation to continue.')
            else:
                self.emit('Connect your assigned iPhone and verify your invitation to continue.')

    def sign_in(self, email, password):
        email = email.strip()
        if not email or not password:
            raise RuntimeError('Enter your Apple Account and password.')
        def run():
            self.require_access()
            from ipaside_engine import gsa
            self.emit('Signing in directly to Apple. First-time device authentication can take a few minutes...')
            try:
                gsa._clear_pending()
                with authentication_stages(gsa):
                    result = gsa.begin_login(email, password)
                if result.get('status') == '2fa_required':
                    answer, ready = [], threading.Event()
                    self.events.put(('code', ('Enter the verification code Apple sent you.', answer, ready)))
                    ready.wait()
                    if not answer[0]:
                        raise RuntimeError('Sign-in cancelled.')
                    code = answer[0].strip()
                    try:
                        if len(code) != 6 or not code.isascii() or not code.isdigit():
                            raise RuntimeError('Enter the six-digit code from the current Apple sign-in prompt.')
                        with authentication_stages(gsa):
                            result = gsa.complete_2fa(email, password, code)
                    except AuthenticationStageError:
                        raise
                    except Exception:
                        raise RuntimeError('Sign-in could not finish after code entry. No sign-in was confirmed; keep the installed app.') from None
                    finally:
                        answer.clear()
                        code = ''
                if result.get('status') != 'authenticated':
                    raise RuntimeError('Apple sign-in did not finish.')
                self.emit('Signed in. Click Continue to choose your IPA.')
            except Exception as error:
                clear = getattr(gsa, '_catter_clear_session', None)
                if clear is not None:
                    clear()
                from local_macos_metadata import LocalMetadataError
                eligible = isinstance(error, LocalMetadataError) or (
                    isinstance(error, AuthenticationStageError) and any(code in str(error) for code in ('-80045', '-80046', '-23782')))
                if sys.platform in ('win32', 'darwin') and eligible and not self.remote_metadata_enabled:
                    if self.ask_phone_step('Try macOS authentication metadata?',
                        'Local Apple authentication could not finish. An optional remote Mac metadata provider may help.\n\n'
                        'mac-ani.jkcoxson.com receives a random device identifier, provisioning blobs and your IP address. '
                        'Your Apple email, password, verification code, account token and signing key are never sent to it. '
                        'Apple may list this sign-in as a Mac device in your account. Closing setup clears local session data but does not remove that Apple Account entry. '
                        'Metadata is kept only while setup is open.\n\n'
                        'Continue enables this provider for this session. Then sign in again. Cancel keeps local authentication.'):
                        from remote_anisette import enable
                        self.mac_metadata = enable(gsa, consent=True)
                        self.remote_metadata_enabled = True
                        raise RuntimeError('macOS metadata enabled for this setup session. Sign in again with your verified email. No sign-in has been confirmed yet.') from None
                # Never echo the password even if an upstream error includes it.
                raise RuntimeError(str(error).replace(password, '[redacted]')) from None
            finally:
                from ipaside_engine import paths
                paths.pending_2fa_file().unlink(missing_ok=True)
        self.work(run)

    def install(self):
        if not self.ipa:
            raise RuntimeError('Choose a Catter IPA first.')
        ipa = self.ipa
        expected_digest = self.ipa_digest
        def run():
            self.require_access()
            from ipaside_engine import device, gsa, sideload, developer
            # Sign a private snapshot, never a mutable external input path.
            with tempfile.TemporaryDirectory(prefix='install-', dir=self.private) as temporary:
                snapshot = Path(temporary) / 'Catter.ipa'
                shutil.copyfile(ipa, snapshot)
                inspect_ipa(snapshot)
                if file_digest(snapshot) != expected_digest:
                    raise RuntimeError('The selected IPA changed. Choose it again before installing.')
                if not gsa.status().get('authenticated'):
                    raise RuntimeError('Sign in to Apple first.')
                check_target(self.target, device.list_devices())
                self.emit('Signing and installing Catter. Keep the phone connected and unlocked...')
                with certificate_recovery(developer, self.choose_certificate,
                        lambda cert: self.ask_phone_step('Replace this signing certificate?',
                            f"Certificate: {cert.get('machineName') or 'Unnamed'}\nSerial: {cert['serialNumber']}\n\n"
                            'Revoking this certificate can stop apps installed by Sideloadly or other tools from opening. Those apps may need reinstalling. This cannot be undone.\n\n'
                            'Replace this certificate and retry Catter installation?')):
                    result = sideload.run_sideload(str(snapshot), udid=self.target, record=False, remove_uisd=False,
                        on_progress=lambda phase, percent, step: self.emit(step or phase))
                if result.get('status') != 'installed' or not result.get('bundle_id'):
                    raise RuntimeError('The signing engine did not confirm an installed app.')
            self.emit('App installed. Checking iPhone preparation...')
            bootstrap = None
            try:
                if self.ask_phone_step('Enable on-device renewal?',
                        'Copy this app\'s signing certificate and private key to this iPhone? '
                        'Catter will protect them in Keychain and use them to renew itself without the computer. '
                        'Your Apple password and login session are not transferred.\n\n'
                        'You must sign in inside Catter to enable renewal. Automatic renewal is optional and depends on iOS allowing it. '
                        'Cancel skips renewal setup; ordinary installation still continues.'):
                    from renewal import make_bootstrap
                    folder = self.private / 'devices' / hashlib.sha256(self.target.encode()).hexdigest()[:24]
                    folder.mkdir(parents=True, exist_ok=True)
                    bootstrap = folder / 'renewal-bootstrap.json'
                    bootstrap.write_bytes(make_bootstrap(result['bundle_id'], self.target))
                self.prepare_target(renewal_bootstrap=bootstrap)
            finally:
                if bootstrap is not None: bootstrap.unlink(missing_ok=True)
        self.work(run)

    def prepare_target(self, replace_unrecognized_backup=False, renewal_bootstrap=None):
        if not replace_unrecognized_backup:
            self.emit('Before preparation: enable Developer Mode on your iPhone. See the setup instructions.')
            if not self.ask_phone_step('Get your iPhone ready',
                    'On your iPhone, open Settings > Privacy & Security > Developer Mode.\n\n'
                    'Turn it on, let the iPhone restart, unlock it and confirm Turn On. '
                    'Keep the USB cable connected. Accept Trust and enter your passcode if asked.\n\n'
                    'Developer Mode does not show an automatic pop-up: open Settings yourself. '
                    'If the switch is missing, install Catter first, then return here.\n\n'
                    'If Developer Mode is already on, no restart is needed. '
                    'Click Continue only when the iPhone is unlocked and ready. '
                    'Cancel leaves the installed app in place.'):
                self.emit('Preparation paused. When your iPhone is ready, choose Continue preparation.')
                return
        from ipaside_engine import device
        check_target(self.target, device.list_devices())
        folder = self.private / 'devices' / hashlib.sha256(self.target.encode()).hexdigest()[:24]
        folder.mkdir(parents=True, exist_ok=True)
        self.emit('Checking the USB connection and Developer Mode. Keep your iPhone unlocked...')
        command = [sys.executable, '-B', '-E', '-u', '-X', 'utf8', str(ROOT / 'scripts' / 'prepare_device.py'),
                   '--native', str(ROOT / 'native' / ('idevice-tools.exe' if os.name == 'nt' else 'idevice-tools')), '--private-dir', str(folder),
                   '--udid', self.target, '--access-binding', str(folder / 'access-binding.json')]
        if replace_unrecognized_backup:
            command.append('--replace-unrecognized-backup')
        if renewal_bootstrap is not None:
            command.extend(['--renewal-bootstrap', str(renewal_bootstrap)])
        needs_developer_mode = False
        rejected_backup = False
        last_error = None
        with subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, encoding='utf-8', errors='replace', creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0)) as child:
            for line in preparation_output(child, self.emit):
                if 'PAIRING_BACKUP_REJECTED:' in line:
                    rejected_backup = True
                if line.startswith('Preparation stopped:'):
                    last_error = line.strip().replace(self.target, '[device]')
                if 'Enable Settings > Privacy & Security > Developer Mode' in line:
                    needs_developer_mode = True
                self.emit(line.strip().replace(self.target, '[device]'))
            if child.wait() != 0:
                if rejected_backup and not replace_unrecognized_backup:
                    if self.ask_phone_step('Create new iPhone pairing?',
                            'The app has no pairing, and this iPhone rejected the saved computer backup.\n\n'
                            'Create a fresh pairing now? The old backup will be kept privately. Keep the phone unlocked and accept any system prompt. No location will be changed.'):
                        return self.prepare_target(replace_unrecognized_backup=True, renewal_bootstrap=renewal_bootstrap)
                    self.emit('Preparation cancelled. No pairing was transferred. Click Continue preparation to retry.')
                    return
                if needs_developer_mode:
                    self.ask_phone_step('Enable Developer Mode on your iPhone',
                        'Catter is installed. On your iPhone:\n\n'
                        '1. Open Settings > Privacy & Security > Developer Mode.\n'
                        '2. Turn it on, restart, unlock and confirm Turn On.\n'
                        '3. Keep USB connected.\n\n'
                        'After returning here, click Continue preparation. You do not need to reinstall.')
                    self.emit('Waiting for Developer Mode. When the phone is ready, click Continue preparation.')
                    return
                raise RuntimeError(last_error or 'Preparation stopped. See technical details, then Continue preparation. Keep the installed app.')
        self.emit('Setup complete. Join Wi-Fi, connect LocalDevVPN and open Catter.')
        self.ask_phone_step('Your iPhone is prepared',
            'Join a Wi-Fi network. Install LocalDevVPN from the App Store and connect it, then open Catter.\n\n'
            'If iOS asks you to trust the developer, open Settings > General > VPN & Device Management and trust your Apple Account.\n\n'
            'Test Set and Restore before unplugging. Setup has not changed or verified your location. Reinstall manually every seven days with a free Apple Account.')

    def prepare(self):
        def run():
            self.require_access()
            from ipaside_engine import device
            if self.target is None:
                self.target = one_usb_device(device.list_devices())
            self.prepare_target()
        self.work(run)

    def forget(self):
        def run():
            self.access_code = None
            from ipaside_engine import gsa, paths
            sign_out(gsa, paths)
            self.events.put(('signed_out', None))
            self.emit('Signed out. Local account tokens and pending verification sessions were removed and checked. Signing certificates and phone pairing are retained; Apple decides whether the next sign-in needs a code.')
        self.work(run)
