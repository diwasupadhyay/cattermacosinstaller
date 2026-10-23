import plistlib
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
import stat

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from core import inspect_ipa, one_usb_device, check_target


class PolicyTests(unittest.TestCase):
    def test_device_selection_does_not_choose_wifi_or_another_phone(self):
        devices = [{'serial': 'phone-a', 'connection_type': 'USB'},
                   {'serial': 'phone-b', 'connection_type': 'Network'}]
        self.assertEqual(one_usb_device(devices), 'phone-a')
        self.assertEqual(check_target('phone-a', devices), 'phone-a')
        with self.assertRaises(RuntimeError):
            check_target('phone-b', devices)
        with self.assertRaises(RuntimeError):
            one_usb_device(devices + [{'serial': 'phone-c', 'connection_type': 'USB'}])
        with self.assertRaises(RuntimeError):
            one_usb_device([devices[1]])

    def test_ipa_validation(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'test.ipa'
            def create(identity, extra=None):
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr('Payload/Ghostly.app/Info.plist', plistlib.dumps({
                        'CFBundleIdentifier': identity, 'CFBundleVersion': '8'}))
                    if extra:
                        archive.writestr(extra, b'x')
            create('com.diwasupadhyay.ghostlyios')
            self.assertEqual(inspect_ipa(path)['CFBundleVersion'], '8')
            create('com.diwasupadhyay.ghostlyios.TEAM')
            inspect_ipa(path)
            create('com.other.app')
            with self.assertRaises(ValueError):
                inspect_ipa(path)
            for unsafe in ['../escape', '/absolute', 'Payload/../escape', 'C:/escape', 'Payload\\..\\escape']:
                create('com.diwasupadhyay.ghostlyios', unsafe)
                with self.assertRaises(ValueError):
                    inspect_ipa(path)

    def test_rejects_links_and_windows_aliases(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'test.ipa'
            for extra in ['Payload/Ghostly.app/info.plist', 'Payload/CON.txt',
                          'Payload/trailing.', 'Payload/trailing ', 'Payload/link']:
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr('Payload/Ghostly.app/Info.plist', plistlib.dumps({
                        'CFBundleIdentifier': 'com.diwasupadhyay.ghostlyios'}))
                    entry = zipfile.ZipInfo(extra)
                    if extra.endswith('/link'):
                        entry.create_system = 3
                        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(entry, '../outside')
                with self.assertRaises(ValueError, msg=extra):
                    inspect_ipa(path)


if __name__ == '__main__':
    unittest.main()
