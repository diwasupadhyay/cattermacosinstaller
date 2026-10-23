import plistlib
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import prepare_device as preparation


class PairingTests(unittest.IsolatedAsyncioTestCase):
    async def test_classic_record_requires_matching_device_and_verified_transfer(self):
        record = {key: b'test-only' for key in ('DeviceCertificate', 'HostCertificate',
                  'HostPrivateKey', 'RootCertificate', 'RootPrivateKey')}
        record.update(HostID='test-host', SystemBUID='test-system', WiFiMACAddress='test-mac', UDID='test-phone')
        data = plistlib.dumps(record)
        for mode in ('wrong-device', 'setting-rejected', 'transfer-corrupt', 'success'):
            device = SimpleNamespace(pair_record=record, set_value=AsyncMock(),
                                     get_value=AsyncMock(return_value=mode != 'setting-rejected'))
            container = SimpleNamespace(makedirs=AsyncMock(), set_file_contents=AsyncMock(),
                rename=AsyncMock(), get_file_contents=AsyncMock(return_value=b'corrupt' if mode == 'transfer-corrupt' else data))
            if mode == 'success':
                await preparation.prepare_classic_transport(device, container, 'test-phone')
                container.rename.assert_awaited_once()
            else:
                with self.assertRaises(RuntimeError):
                    await preparation.prepare_classic_transport(device, container, 'other' if mode == 'wrong-device' else 'test-phone')
                container.rename.assert_not_awaited()
                if mode == 'wrong-device':
                    device.set_value.assert_not_awaited()

    async def test_only_verified_new_pairing_is_transferred(self):
        for verified in [False, True]:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                data = plistlib.dumps({'public_key': b'p' * 32, 'private_key': b's' * 32, 'identifier': 'test'})
                def native(command):
                    if 'rppairing' in command:
                        Path(command[-1]).write_bytes(data)
                        return ''
                    return 'the device recognizes this pairing record' if verified else 'pair-verify failed'
                container = SimpleNamespace(makedirs=AsyncMock(), set_file_contents=AsyncMock(),
                    rename=AsyncMock(), get_file_contents=AsyncMock(return_value=data))
                args = SimpleNamespace(private_dir=root, native=Path('mock-native'))
                record = root / 'remote-pairing.plist'
                with patch.object(preparation, 'native', side_effect=native):
                    if verified:
                        await preparation.create_pairing(container, args, 'test-phone', record)
                        self.assertEqual(record.read_bytes(), data)
                        container.set_file_contents.assert_awaited_once()
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'not verified'):
                            await preparation.create_pairing(container, args, 'test-phone', record)
                        container.set_file_contents.assert_not_awaited()
                        self.assertFalse(record.exists())
