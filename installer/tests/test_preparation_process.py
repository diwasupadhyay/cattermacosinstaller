import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from service import preparation_output

class PreparationProcessTests(unittest.TestCase):
    def test_silent_helper_times_out_and_exits(self):
        with subprocess.Popen([sys.executable,'-u','-c','import time;time.sleep(20)'],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,text=True) as child:
            with self.assertRaisesRegex(RuntimeError,'did not respond'):
                list(preparation_output(child,lambda _:None,startup_timeout=.1))
            self.assertIsNotNone(child.poll())
    def test_output_is_streamed(self):
        with subprocess.Popen([sys.executable,'-u','-c','print("ready",flush=True)'],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,text=True) as child:
            self.assertEqual(list(preparation_output(child,lambda _:None)),['ready\n'])
            self.assertEqual(child.wait(timeout=5),0)
    @unittest.skipUnless(os.name=='nt','Windows anonymous-pipe regression')
    def test_actual_service_does_not_inherit_busy_input_pipe(self):
        # The child inherits a live IPC pipe, like the WPF-launched backend.
        # prepare_target must isolate its own helper's stdin to start Python.
        code=r'''
import sys,threading,time,tempfile,types
from pathlib import Path
from unittest.mock import patch,MagicMock
sys.path.insert(0,sys.argv[1])
from service import InstallerService
import service
threading.Thread(target=lambda:sys.stdin.readline(),daemon=True).start()
time.sleep(.1)
with tempfile.TemporaryDirectory() as d:
 root=Path(d);(root/'scripts').mkdir()
 (root/'scripts/prepare_device.py').write_text('print("helper started",flush=True)')
 app=InstallerService.__new__(InstallerService)
 app.target='synthetic';app.private=root;app.ask_phone_step=lambda *a:True
 app.emit=lambda text:print(text,flush=True)
 with patch.object(service,'ROOT',root),patch.object(service,'check_target'),patch.dict(sys.modules,{'ipaside_engine':types.SimpleNamespace(device=types.SimpleNamespace(list_devices=lambda:[]))}):
  app.prepare_target()
 print('TEST COMPLETE',flush=True)
'''
        p=subprocess.Popen([sys.executable,'-u','-c',code,str(Path(__file__).resolve().parents[1])],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        messages=queue.Queue()
        def read():
            for line in p.stdout:messages.put(line)
        threading.Thread(target=read,daemon=True).start()
        try:
            while 'TEST COMPLETE' not in messages.get(timeout=10):pass
        finally:
            p.stdin.close()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()
            p.stdout.close();p.stderr.close()
        self.assertEqual(p.returncode,0)
