from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from account_security import sign_out


class SignOutTests(unittest.TestCase):
    def test_removes_all_sessions_but_preserves_pairing_and_signing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session = root / 'session'
            (session / 'accounts').mkdir(parents=True)
            for name in ['active.json', 'account.json', 'pending.json', 'accounts/broken.json', 'unknown-token']:
                (session / name).write_text('invalid or cached data')
            (root / 'pairing.plist').write_text('keep')
            (root / 'signing-key').write_text('keep')
            paths = SimpleNamespace(data_dir=lambda: root, session_dir=lambda: session)
            api = SimpleNamespace(status=Mock(return_value={'authenticated': False}))
            sign_out(api, paths)
            self.assertFalse(any(p.is_file() for p in session.rglob('*')))
            self.assertTrue((root / 'pairing.plist').exists())
            self.assertTrue((root / 'signing-key').exists())
            sign_out(api, paths)  # Repeated logout is safe.

    def test_unexpected_directory_is_not_deleted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            token = root / 'token'
            token.write_text('keep')
            paths = SimpleNamespace(data_dir=lambda: root, session_dir=lambda: root)
            with self.assertRaisesRegex(RuntimeError, 'Unexpected session'):
                sign_out(Mock(), paths)
            self.assertTrue(token.exists())


class AuthenticationStageTests(unittest.TestCase):
    def test_stage_and_code_preserved_without_response_secrets(self):
        from account_security import authentication_stages
        for failing in ['_submit_trusted', '_authenticate_once', '_fetch_app_token']:
            api = SimpleNamespace(**{name: Mock(return_value=True) for name in ['_submit_trusted', '_submit_sms', '_authenticate_once', '_fetch_app_token']})
            original = getattr(api, failing)
            original.side_effect = RuntimeError('Apple error -80046: secret-token password verification-code')
            with authentication_stages(api):
                with self.assertRaises(RuntimeError) as caught:
                    getattr(api, failing)()
                self.assertIn('-80046', str(caught.exception))
                self.assertNotIn('secret-token', str(caught.exception))
                self.assertNotIn('password', str(caught.exception))
            self.assertIs(getattr(api, failing), original)

    def test_success_is_returned_unchanged(self):
        from account_security import authentication_stages
        api = SimpleNamespace(**{name: Mock(return_value={'ok': True}) for name in ['_submit_trusted', '_submit_sms', '_authenticate_once', '_fetch_app_token']})
        with authentication_stages(api):
            self.assertEqual(api._submit_trusted(), {'ok': True})
