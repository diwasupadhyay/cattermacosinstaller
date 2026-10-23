import json
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from access import check_update

class UpdateTests(unittest.TestCase):
    def test_numeric_versions_platform_and_fixed_origin(self):
        opener = MagicMock()
        response = opener.open.return_value.__enter__.return_value
        response.status = 200
        with patch.object(Path, 'read_text', return_value='{"url":"https://example.test"}'), patch('access.build_opener', return_value=opener):
            for platform, version, expected in [('windows','0.12.0','0.12.0'), ('macos','9.0.0',None), ('windows','0.8.1',None), ('windows','bad',None)]:
                response.read.return_value = json.dumps({'releases':[{'platform':platform,'version':version}]}).encode()
                self.assertEqual(check_update('windows'), expected)
            request = opener.open.call_args.args[0]
            self.assertEqual(request.full_url, 'https://example.test/api/releases')
            self.assertEqual(request.get_header('User-agent'), 'CatterSetup/0.11.0')
            self.assertIsNone(request.data)
            self.assertIsNone(request.get_header('Authorization'))
    def test_large_response_rejected(self):
        opener = MagicMock()
        response = opener.open.return_value.__enter__.return_value
        response.status = 200; response.read.return_value = b' ' * 16385
        with patch.object(Path, 'read_text', return_value='{"url":"https://example.test"}'), patch('access.build_opener', return_value=opener):
            with self.assertRaises(ValueError): check_update('windows')
