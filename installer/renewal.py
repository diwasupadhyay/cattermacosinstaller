"""Explicit, one-time USB handoff of the identity that signed Catter.

Never include Apple login/session tokens. The iPhone verifies this certificate
against its installed profile, saves it in Keychain, then removes the handoff.
"""
import base64
import json
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.serialization import pkcs12


def make_bootstrap(bundle_id, udid):
    from ipaside_engine import provision
    key_pem, cert_der, _ = provision.signing_identity()
    key = serialization.load_pem_private_key(key_pem, password=None)
    certificate = x509.load_der_x509_certificate(cert_der)
    if key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo) != certificate.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo):
        raise RuntimeError('Renewal signing key and certificate do not match.')
    p12 = pkcs12.serialize_key_and_certificates(b'Catter Renewal', key, certificate, None, serialization.NoEncryption())
    return json.dumps({'bundleID': bundle_id, 'udid': udid, 'p12': base64.b64encode(p12).decode('ascii')}).encode()
