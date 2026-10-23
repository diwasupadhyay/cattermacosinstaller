import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from branding import storage_namespace


class BrandingCompatibilityTests(unittest.TestCase):
    def test_new_installation_uses_catter(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(storage_namespace(root), 'CatterInstaller')

    def test_existing_private_material_is_reused_without_copying(self):
        with tempfile.TemporaryDirectory() as root:
            backup = Path(root) / 'GhostlyInstaller' / 'devices'
            backup.mkdir(parents=True)
            record = backup / 'test-record'
            record.write_bytes(b'test-only')
            self.assertEqual(storage_namespace(root), 'GhostlyInstaller')
            self.assertEqual(record.read_bytes(), b'test-only')
            self.assertFalse((Path(root) / 'CatterInstaller').exists())
