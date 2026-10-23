from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import json

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from remote_anisette import MacMetadata, apple_url, value, ORIGIN


class MetadataTests(unittest.TestCase):
    def test_endpoint_validation(self):
        for address in ['http://gsa.apple.com/test', 'https://gsa.apple.com.evil.test/',
                        'https://user@gsa.apple.com/', 'https://gsa.apple.com:8443/',
                        'https://evil.test/', 'https://gsa.apple.com/#secret']:
            with self.assertRaises(RuntimeError):
                apple_url(address)
        self.assertEqual(apple_url('https://gsa.apple.com/grandslam/test'), 'https://gsa.apple.com/grandslam/test')

    def test_remote_output_cannot_inject_credentials_or_headers(self):
        provider = MacMetadata()
        provider.info = {'client_info': '<Mac> <AuthKit>', 'user_agent': 'akd/test'}
        provider.blob = 'dGVzdA=='
        reply = {'X-Apple-I-MD': 'b3Rw', 'X-Apple-I-MD-M': 'bWFjaGluZQ==', 'X-Apple-I-MD-RINFO': '1',
                 'Authorization': 'malicious', 'Cookie': 'malicious'}
        with patch('remote_anisette.request', return_value=json.dumps(reply).encode()) as send:
            result = provider.headers()
        self.assertNotIn('Authorization', result)
        self.assertNotIn('Cookie', result)
        self.assertEqual(send.call_args.args[0], ORIGIN + '/v3/get_headers')
        self.assertEqual(set(json.loads(send.call_args.kwargs['payload'])), {'identifier', 'adi_pb'})

    def test_error_body_is_never_shown(self):
        with patch('remote_anisette.request', side_effect=RuntimeError('private-payload')):
            with self.assertRaises(RuntimeError) as caught:
                MacMetadata().headers()
        self.assertNotIn('private-payload', str(caught.exception))
        with self.assertRaises(RuntimeError):
            value({'x': 'value\r\nAuthorization: secret'}, 'x')
