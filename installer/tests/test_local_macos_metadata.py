import json
import base64
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from local_macos_metadata import LocalMacMetadata


class LocalMacTests(unittest.TestCase):
    def reply(self, **changes):
        fields = dict(otp='b3Rw', machine='bWFjaGluZQ==',
                      identifier='12345678-1234-1234-1234-123456789012',
                      user_agent='akd/1.0 Darwin/24.0.0',
                      client='<Mac14,7> <macOS;15.0.0;24A335> <com.apple.AuthKit/1 (com.apple.akd/1.0)>')
        fields.update(changes)
        return SimpleNamespace(stdout=json.dumps(fields).encode())

    def test_local_identity_and_no_secret_passed_to_helper(self):
        with patch('local_macos_metadata.sys.platform', 'darwin'), patch.dict('os.environ', {'IPASIDE_APPLE_PASSWORD': 'secret'}), patch('local_macos_metadata.subprocess.run', return_value=self.reply()) as run:
            headers = LocalMacMetadata().headers()
        self.assertEqual(headers['X-Mme-Device-Id'], '12345678-1234-1234-1234-123456789012')
        self.assertEqual(base64.b64decode(headers['X-Apple-I-MD-LU']).decode(),
                         '12345678-1234-1234-1234-123456789012')
        self.assertNotIn('IPASIDE_APPLE_PASSWORD', run.call_args.kwargs['env'])
        self.assertEqual(len(run.call_args.args[0]), 1)
        self.assertEqual(run.call_args.kwargs['timeout'], 20)

    def test_native_identity_bytes_are_preserved_as_a_pair(self):
        identity = 'abcdef12-abcd-abcd-abcd-abcdef123456'
        with patch('local_macos_metadata.sys.platform', 'darwin'), patch('local_macos_metadata.subprocess.run', return_value=self.reply(identifier=identity)):
            headers = LocalMacMetadata().headers()
        self.assertEqual(headers['X-Mme-Device-Id'], identity)
        self.assertEqual(base64.b64decode(headers['X-Apple-I-MD-LU']).decode(), identity)

    def test_native_failure_is_redacted_and_does_not_fall_back(self):
        with patch('local_macos_metadata.sys.platform', 'darwin'), patch('local_macos_metadata.subprocess.run', side_effect=subprocess.CalledProcessError(3, 'helper', stderr=b'private-metadata')):
            with self.assertRaisesRegex(RuntimeError, 'No remote metadata provider') as caught:
                LocalMacMetadata().headers()
        self.assertNotIn('private-metadata', str(caught.exception))
        self.assertIn('M03', str(caught.exception))

    def test_missing_helper_and_timeout_are_distinguished(self):
        for error, code in ((FileNotFoundError('private-path'), 'M09'),
                            (subprocess.TimeoutExpired('private-command', 20), 'M08'),
                            (subprocess.CalledProcessError(-9, 'private-command'), 'M07')):
            with patch('local_macos_metadata.sys.platform', 'darwin'), patch('local_macos_metadata.subprocess.run', side_effect=error):
                with self.assertRaises(RuntimeError) as caught:
                    LocalMacMetadata().headers()
                self.assertIn(code, str(caught.exception))
                self.assertNotIn('private-', str(caught.exception))

    def test_invalid_native_output_is_rejected(self):
        for changes in ({'client': 'value\r\nInjected: bad'}, {'identifier': 'invalid'}, {'otp': '!not-base64'}, {'machine': ''}, {'client': '<Windows>'}, {'user_agent': 'Windows'}):
            with patch('local_macos_metadata.sys.platform', 'darwin'), patch('local_macos_metadata.subprocess.run', return_value=self.reply(**changes)):
                with self.assertRaises(RuntimeError):
                    LocalMacMetadata().headers()

    def test_remote_requires_consent_before_network(self):
        from remote_anisette import enable
        with patch('remote_anisette.sys.platform', 'darwin'), patch('remote_anisette.request') as request:
            with self.assertRaises(RuntimeError):
                enable(SimpleNamespace())
            request.assert_not_called()

    def test_local_provider_updates_gsa_identity_without_network(self):
        from local_macos_metadata import enable
        gsa = SimpleNamespace(anisette=SimpleNamespace(), _GS_USER_AGENT='Windows')
        with patch('local_macos_metadata.sys.platform', 'darwin'), patch('local_macos_metadata.subprocess.run', return_value=self.reply()):
            enable(gsa)
            headers = gsa.anisette.get_headers()
        self.assertEqual(gsa._GS_USER_AGENT, headers['User-Agent'])
        self.assertIn('<macOS;', headers['X-MMe-Client-Info'])
        self.assertNotIn('Windows', str(headers))

    def test_remote_mac_provider_requires_explicit_true(self):
        from remote_anisette import enable
        for consent in (False, None, 'yes'):
            with patch('remote_anisette.sys.platform', 'darwin'), patch('remote_anisette.request') as request:
                with self.assertRaises(RuntimeError):
                    enable(SimpleNamespace(), consent=consent)
                request.assert_not_called()
        gsa = SimpleNamespace(anisette=SimpleNamespace())
        with patch('local_macos_metadata.LocalMacMetadata.client_info', return_value={'client_info': '<Mac> <macOS;27.0>', 'user_agent': 'akd/1.0 Darwin/26'}), patch('remote_anisette.sys.platform', 'darwin'), patch('remote_anisette.request', return_value=b'{"client_info":"<Mac> <macOS;15>","user_agent":"akd/test"}'):
            provider = enable(gsa, consent=True)
        self.assertIs(gsa.anisette.get_headers.__self__, provider)

    def test_host_description_does_not_request_otp(self):
        with patch('local_macos_metadata.sys.platform', 'darwin'), patch('local_macos_metadata.subprocess.run', return_value=self.reply()) as run:
            info = LocalMacMetadata().client_info()
        self.assertEqual(run.call_args.args[0][-1], '--client-info')
        self.assertEqual(set(info), {'client_info', 'user_agent'})
        self.assertNotIn('identifier', info)

    def test_remote_uses_host_description_without_replacing_provisioning_identity(self):
        from remote_anisette import enable
        old = b'{"client_info":"<MacBookPro13,3> <Mac OS X;10.12.6;16G29>","user_agent":"old"}'
        host = {'client_info': '<Mac17,3> <macOS;27.0;26A> <com.apple.AuthKit/1 (com.apple.akd/1.0)>', 'user_agent': 'akd/1.0 Darwin/26'}
        gsa = SimpleNamespace(anisette=SimpleNamespace())
        with patch('remote_anisette.sys.platform', 'darwin'), patch('remote_anisette.request', return_value=old), patch('local_macos_metadata.LocalMacMetadata.client_info', return_value=host):
            provider = enable(gsa, consent=True)
        identifier = provider.identifier
        headers = provider._base()
        self.assertEqual(headers['X-MMe-Client-Info'], host['client_info'])
        self.assertEqual(gsa._GS_USER_AGENT, host['user_agent'])
        self.assertEqual(headers['X-Mme-Device-Id'], str(identifier).upper())
        self.assertIsNone(provider.blob)

    def test_host_description_rejects_injected_headers(self):
        with patch('local_macos_metadata.sys.platform', 'darwin'), patch('local_macos_metadata.subprocess.run', return_value=self.reply(client='private\r\nInjected: value')):
            with self.assertRaisesRegex(RuntimeError, 'M11') as caught:
                LocalMacMetadata().client_info()
        self.assertNotIn('private', str(caught.exception))
