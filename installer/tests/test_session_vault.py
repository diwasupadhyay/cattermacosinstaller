import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from session_vault import SessionVault, MAX_AGE


class FakeVault:
    def __init__(self): self.values = {}
    def get_password(self, service, name): return self.values.get((service, name))
    def set_password(self, service, name, value): self.values[service, name] = value
    def delete_password(self, service, name): self.values.pop((service, name), None)


class SessionVaultTests(unittest.TestCase):
    def test_encryption_expiry_and_no_password_storage(self):
        with tempfile.TemporaryDirectory() as folder, patch('session_vault.vault', return_value=FakeVault()):
            cache = SessionVault(folder)
            account = {'email': 'test@example.invalid', 'auth_token': 'test-only-token', 'password': 'must-not-save', 'code': '123456'}
            with patch('session_vault.time.time', return_value=1000):
                cache.save(account)
                raw = cache.file.read_bytes()
                self.assertNotIn(b'test-only-token', raw)
                self.assertEqual(set(cache.load()['account']), {'email', 'auth_token'})
            with patch('session_vault.time.time', return_value=1000 + MAX_AGE):
                self.assertIsNone(cache.load())
                self.assertFalse(cache.file.exists())

    def test_close_does_not_extend_expiry_and_tampering_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder, patch('session_vault.vault', return_value=FakeVault()):
            cache = SessionVault(folder)
            account = {'email': 'test@example.invalid', 'auth_token': 'test-only'}
            with patch('session_vault.time.time', return_value=1000):
                expires = cache.save(account)
            with patch('session_vault.time.time', return_value=2000):
                self.assertEqual(cache.save(account, expires=expires), expires)
                self.assertEqual(cache.load()['expires'], expires)
                cache.file.write_bytes(cache.file.read_bytes()[:-10] + b'corruption')
                self.assertIsNone(cache.load())
                self.assertFalse(cache.file.exists())

    def test_forget_removes_key_and_ciphertext(self):
        store = FakeVault()
        with tempfile.TemporaryDirectory() as folder, patch('session_vault.vault', return_value=store):
            cache = SessionVault(folder)
            cache.save({'email': 'test@example.invalid', 'auth_token': 'test-only'})
            cache.forget()
            self.assertFalse(cache.file.exists())
            self.assertEqual(store.values, {})
