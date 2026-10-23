import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from certificates import certificate_recovery


class CertificateTests(unittest.TestCase):
    def test_upstream_automatic_revocation_also_requires_consent(self):
        api = self.api()
        with certificate_recovery(api, Mock(), lambda cert: False):
            with self.assertRaisesRegex(RuntimeError, 'cancelled'):
                api.revoke_certificate('team', 'chosen')
        api.revoke_certificate.assert_not_called()

    def api(self, code='7460'):
        error = type('DeveloperServicesError', (Exception,), {})
        return SimpleNamespace(DeveloperServicesError=error,
            submit_csr=Mock(side_effect=[error(code + ': blocked'), {'ok': True}]),
            list_certificates=Mock(return_value=[{'serialNumber': 'chosen', 'machineName': 'Sideloadly'}, {'serialNumber': 'other'}]),
            revoke_certificate=Mock())

    def test_only_selected_certificate_revoked_and_original_restored(self):
        api = self.api()
        original = api.submit_csr
        with certificate_recovery(api, lambda cs: 'chosen', lambda cert: True):
            self.assertEqual(api.submit_csr('team', 'csr'), {'ok': True})
        api.revoke_certificate.assert_called_once_with('team', 'chosen')
        self.assertIs(api.submit_csr, original)
        self.assertEqual(original.call_count, 2)

    def test_cancel_does_not_revoke(self):
        for selected, confirmed in [(None, True), ('chosen', False), ('unknown', True)]:
            api = self.api()
            with certificate_recovery(api, lambda cs: selected, lambda c: confirmed):
                with self.assertRaisesRegex(RuntimeError, 'cancelled'):
                    api.submit_csr('team', 'csr')
            api.revoke_certificate.assert_not_called()

    def test_other_errors_never_offer_replacement(self):
        api = self.api('1234')
        choose = Mock()
        with certificate_recovery(api, choose, Mock()):
            with self.assertRaises(api.DeveloperServicesError):
                api.submit_csr('team', 'csr')
        choose.assert_not_called()
        api.revoke_certificate.assert_not_called()

    def test_changed_certificate_not_revoked(self):
        api = self.api()
        api.list_certificates.side_effect = [[{'serialNumber': 'chosen'}], []]
        with certificate_recovery(api, lambda cs: 'chosen', lambda c: True):
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                api.submit_csr('team', 'csr')
        api.revoke_certificate.assert_not_called()

    def test_retry_failure_reports_revocation_without_revoking_more(self):
        api = self.api()
        api.submit_csr.side_effect = [api.DeveloperServicesError('7460: blocked')] * 2
        with certificate_recovery(api, lambda cs: 'chosen', lambda c: True):
            with self.assertRaisesRegex(RuntimeError, 'was revoked'):
                api.submit_csr('team', 'csr')
        api.revoke_certificate.assert_called_once()
