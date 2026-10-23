import hashlib
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import invitation_store as store
from access import InvitationRejected
from service import InstallerService


class InvitationTests(unittest.TestCase):
    def test_vault_failure_never_writes_plaintext(self):
        with patch.object(store, 'vault', side_effect=RuntimeError('locked')):
            self.assertIsNone(store.load('phone'))
            self.assertFalse(store.save('phone', 'ab' * 24))
            store.forget('phone')

    def test_reads_only_valid_codes(self):
        backend = MagicMock()
        with patch.object(store, 'vault', return_value=backend):
            backend.get_password.return_value = 'invalid'
            self.assertIsNone(store.load('phone'))
            backend.get_password.return_value = 'ab' * 24
            self.assertEqual(store.load('phone'), 'ab' * 24)

    def test_saved_invitation_is_rechecked_and_revocation_forgets_it(self):
        app = InstallerService.__new__(InstallerService)
        app.access_code = None
        app.target = None
        app.emit = MagicMock()
        phone = {'udid': 'phone-one'}
        from ipaside_engine import device
        with TemporaryDirectory() as folder, patch.object(device, 'list_devices', return_value=[phone]), patch('service.one_usb_device', return_value='phone-one'), patch('service.check_target'), patch.object(store, 'load', return_value='ab' * 24), patch.object(store, 'save', return_value=True), patch.object(store, 'forget') as forget, patch('access.authorize') as authorize:
            app.private = Path(folder)
            authorize.return_value = {'id':'test', 'setupProof':'cd' * 32}
            app.require_access(interactive=False)
            identity = hashlib.sha256(b'catter-usb-v1:phone-one').hexdigest()
            authorize.assert_called_once_with('ab' * 24, identity)
            authorize.side_effect = InvitationRejected('expired')
            app.restore_access()
            self.assertIsNone(app.access_code)
            forget.assert_called_once_with(identity)

    def test_network_failure_keeps_vault_code_but_blocks_access(self):
        app = InstallerService.__new__(InstallerService)
        app.access_code = 'ab' * 24
        app.target = None
        app.emit = MagicMock()
        from ipaside_engine import device
        with patch.object(device, 'list_devices', return_value=[]), patch('service.one_usb_device', return_value='phone'), patch('service.check_target'), patch('access.authorize', side_effect=RuntimeError('offline')), patch.object(store, 'forget') as forget:
            app.restore_access()
            self.assertIsNone(app.access_code)
            forget.assert_not_called()
