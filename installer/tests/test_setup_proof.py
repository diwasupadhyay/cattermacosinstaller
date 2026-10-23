import json
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import prepare_device as preparation

def context(value):
 manager=MagicMock();manager.__aenter__=AsyncMock(return_value=value);manager.__aexit__=AsyncMock(return_value=False);return manager

class SetupProofTests(unittest.IsolatedAsyncioTestCase):
 async def test_proof_transfer_must_read_back_before_pairing_and_mount(self):
  for valid in (True,False):
   with tempfile.TemporaryDirectory() as temporary:
    root=Path(temporary);proof=root/'access-binding.json'
    data=json.dumps({'id':'synthetic','proof':'ab'*32}).encode();proof.write_bytes(data)
    container=SimpleNamespace(exists=AsyncMock(return_value=False),makedirs=AsyncMock(),set_file_contents=AsyncMock(),rename=AsyncMock(),get_file_contents=AsyncMock(return_value=data if valid else b'corrupt'))
    device=SimpleNamespace(get_developer_mode_status=AsyncMock(return_value=True),product_version='test')
    service=SimpleNamespace(get_apps=AsyncMock(return_value={preparation.BASE_ID:{'CFBundleVersion':'21'}}))
    child=SimpleNamespace(wait=AsyncMock(return_value=0))
    args=SimpleNamespace(udid='synthetic',private_dir=root,native=root/'native',access_binding=proof,check_only=False)
    with patch.object(preparation.usbmux,'list_devices',AsyncMock(return_value=[SimpleNamespace(is_usb=True,serial='synthetic')])), patch.object(preparation,'create_using_usbmux',AsyncMock(return_value=context(device))), patch.object(preparation,'InstallationProxyService',return_value=context(service)), patch.object(preparation.HouseArrestService,'create',AsyncMock(return_value=context(container))), patch.object(preparation,'create_pairing',AsyncMock()) as pairing, patch.object(preparation.asyncio,'create_subprocess_exec',AsyncMock(return_value=child)) as mount:
     if valid:
      await preparation.prepare(args)
      pairing.assert_awaited_once();mount.assert_awaited_once()
     else:
      with self.assertRaisesRegex(RuntimeError,'authorization transfer was not verified'):
       await preparation.prepare(args)
      pairing.assert_not_awaited();mount.assert_not_awaited()
    container.set_file_contents.assert_awaited_once_with(preparation.REMOTE_DIRECTORY+'/access-binding.json.tmp',data)
