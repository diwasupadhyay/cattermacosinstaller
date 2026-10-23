import base64
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from renewal import make_bootstrap


class RenewalHandoffTests(unittest.TestCase):
    def test_handoff_contains_matching_identity_but_no_apple_session(self):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Synthetic renewal test')])
        now = datetime.now(timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                .serial_number(1).not_valid_before(now).not_valid_after(now + timedelta(days=1)).sign(key, hashes.SHA256()))
        pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        der = cert.public_bytes(serialization.Encoding.DER)
        with patch('ipaside_engine.provision.signing_identity', return_value=(pem, der, '1')):
            result = json.loads(make_bootstrap('com.example.test', 'synthetic-device'))
        self.assertEqual(set(result), {'bundleID', 'udid', 'p12'})
        self.assertEqual(result['udid'], 'synthetic-device')
        restored_key, restored_cert, _ = pkcs12.load_key_and_certificates(base64.b64decode(result['p12']), None)
        self.assertEqual(restored_cert.serial_number, 1)
        self.assertEqual(restored_key.private_numbers(), key.private_numbers())
        other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        other_pem = other.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        with patch('ipaside_engine.provision.signing_identity', return_value=(other_pem, der, '1')):
            with self.assertRaisesRegex(RuntimeError, 'do not match'):
                make_bootstrap('com.example.test', 'synthetic-device')
