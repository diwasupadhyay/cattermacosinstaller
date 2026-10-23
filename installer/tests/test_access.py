import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch, MagicMock
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from access import authorize, valid_url, NoRedirects


class AccessTests(unittest.TestCase):
    def test_install_and_prepare_check_access_before_device_work(self):
        from service import InstallerService
        service = InstallerService.__new__(InstallerService)
        service.ipa = 'unused.ipa'
        service.ipa_digest = 'unused'
        service.work = lambda fn: fn()
        service.require_access = MagicMock(side_effect=RuntimeError('Access denied'))
        service.prepare_target = MagicMock()
        for operation in (service.install, service.prepare, lambda: service.sign_in("test@example.invalid", "synthetic")):
            with self.assertRaisesRegex(RuntimeError, 'Access denied'):
                operation()
        self.assertEqual(service.require_access.call_count, 3)
        service.prepare_target.assert_not_called()

    def test_only_https_origin_allowed(self):
        self.assertTrue(valid_url('https://catter.example'))
        for value in ('http://example.test', 'https://a:b@example.test', 'https://example.test/path',
                      'https://example.test?code=x', 'file:///a', 'https://example.test#x'):
            self.assertFalse(valid_url(value))

    def test_no_redirect_can_forward_code(self):
        self.assertIsNone(NoRedirects().redirect_request(None, None, 302, '', {}, 'https://other.test'))

    def test_missing_config_and_invalid_code_fail_closed(self):
        with self.assertRaises(RuntimeError):
            authorize('wrong', 'ab' * 32)
        with patch.object(Path, 'read_text', side_effect=FileNotFoundError()), self.assertRaises(RuntimeError):
            authorize('ab' * 24, 'ab' * 32)

    def test_rejected_access_does_not_expose_code(self):
        code = 'ab' * 24
        opener = MagicMock()
        opener.open.side_effect = HTTPError('https://example.test', 403, code, {}, io.BytesIO())
        with patch.object(Path, 'read_text', return_value='{"url":"https://example.test"}'), \
             patch('access.build_opener', return_value=opener):
            with self.assertRaises(RuntimeError) as error:
                authorize(code, "ab" * 32)
            self.assertNotIn(code, str(error.exception))

    def test_expired_response_is_rejected(self):
        opener = MagicMock()
        reply = opener.open.return_value.__enter__.return_value
        reply.status = 200
        reply.read.return_value = json.dumps({'expiresAt': 1, 'serverTime': 2, 'validFor': 60}).encode()
        with patch.object(Path, 'read_text', return_value='{"url":"https://example.test"}'), \
             patch('access.build_opener', return_value=opener), self.assertRaises(RuntimeError):
            authorize('ab' * 24, 'ab' * 32)


class InstallBindingTests(unittest.TestCase):
    def test_swapping_usb_phone_after_authorization_never_starts_signing(self):
        import tempfile
        from types import SimpleNamespace
        from service import InstallerService
        with tempfile.TemporaryDirectory() as directory:
            app = InstallerService.__new__(InstallerService)
            app.ipa = str(Path(directory) / 'input.ipa')
            Path(app.ipa).write_bytes(b'test')
            app.ipa_digest = 'digest'
            app.private = Path(directory)
            app.target = 'authorized-phone'
            app.require_access = MagicMock()
            app.work = lambda fn: fn()
            app.emit = MagicMock()
            sideload = SimpleNamespace(run_sideload=MagicMock())
            engine = SimpleNamespace(
                device=SimpleNamespace(list_devices=lambda: [{'serial': 'other-phone', 'connection_type': 'USB'}]),
                gsa=SimpleNamespace(status=lambda: {'authenticated': True}),
                sideload=sideload, developer=SimpleNamespace())
            with patch.dict(sys.modules, {'ipaside_engine': engine}), patch('service.inspect_ipa'), patch('service.file_digest', return_value='digest'):
                with self.assertRaises(RuntimeError):
                    app.install()
            sideload.run_sideload.assert_not_called()
            self.assertEqual(app.target, 'authorized-phone')
