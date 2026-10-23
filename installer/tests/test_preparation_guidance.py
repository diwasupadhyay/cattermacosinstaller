import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch
import unittest
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import prepare_device as preparation
from service import InstallerService

class PreparationGuidanceTests(unittest.IsolatedAsyncioTestCase):
    async def test_disabled_developer_mode_stops_before_app_access(self):
        device=MagicMock()
        device.__aenter__=AsyncMock(return_value=device)
        device.__aexit__=AsyncMock(return_value=False)
        device.get_developer_mode_status=AsyncMock(return_value=False)
        with patch.object(preparation.usbmux,'list_devices',AsyncMock(return_value=[SimpleNamespace(is_usb=True,serial='test')])), patch.object(preparation,'create_using_usbmux',AsyncMock(return_value=device)), patch.object(preparation,'InstallationProxyService') as apps:
            with self.assertRaisesRegex(RuntimeError,'Enable Settings'):
                await preparation.prepare(SimpleNamespace(udid='test'))
            apps.assert_not_called()
    async def test_connection_timeout_has_actionable_instructions(self):
        async def stalled(): await asyncio.sleep(10)
        with self.assertRaisesRegex(RuntimeError,'timed out.*Unlock'):
            await preparation.checked_step(stalled(),'Connecting',.01)
    def test_cancel_guidance_does_not_start_device_work(self):
        app=InstallerService.__new__(InstallerService)
        app.emit=MagicMock();app.ask_phone_step=MagicMock(return_value=False)
        with patch('service.subprocess.Popen') as child:
            app.prepare_target()
            child.assert_not_called()
        self.assertIn('Developer Mode',app.ask_phone_step.call_args.args[1])
