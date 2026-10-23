"""Run the actual JSON pipe loop with a synthetic Apple engine, never credentials."""
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import unittest

HARNESS = r'''
import sys, types, queue, threading
sys.path.insert(0, sys.argv[1])
class Service:
    def __init__(self):
        self.events=queue.Queue(); self.working=False; self.access_code=None; self.ipa=None
    def close(self): pass
    def work(self, fn):
        self.working=True
        def run():
            try: fn()
            finally: self.events.put(('finished',None))
        threading.Thread(target=run,daemon=True).start()
    def prompt(self, kind, value):
        answer=[]; ready=threading.Event()
        self.events.put((kind,(*value,answer,ready)))
        assert ready.wait(10)
        return answer[0]
    def require_access(self):
        value=self.prompt('access',('Synthetic invitation',))
        if value: self.access_code=value
    def sign_in(self,email,password):
        def run():
            assert self.prompt('code',('Synthetic Apple code',))=='123456'
            assert self.prompt('phone',('Unlock phone','Synthetic device step')) is True
            assert self.prompt('certificates',([{'machineName':'Test','serialNumber':'test'}],)) is None
            self.events.put(('status','All prompts completed'))
        self.work(run)
service=types.ModuleType('service');service.InstallerService=Service;sys.modules['service']=service
engine=types.ModuleType('ipaside_engine');engine.gsa=types.SimpleNamespace(status=lambda:{'authenticated':False})
sys.modules['ipaside_engine']=engine
import backend
backend.main()
'''

class BackendPipeTests(unittest.TestCase):
    def test_activation_gate_and_all_prompt_round_trips(self):
        p=subprocess.Popen([sys.executable,'-u','-c',HARNESS,str(Path(__file__).resolve().parents[1])],
                           stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
                           **({"process_group": 0} if sys.platform == "darwin" else {}))
        received=queue.Queue()
        def read():
            for line in p.stdout: received.put(json.loads(line))
        threading.Thread(target=read,daemon=True).start()
        def send(**value):
            p.stdin.write(json.dumps(value)+'\n');p.stdin.flush()
        def until(kind):
            while True:
                value=received.get(timeout=15)
                if value['type']==kind:return value
        try:
            self.assertFalse(until('state')['access'])
            send(op='login',email='synthetic',password='synthetic')
            self.assertIn('invitation',until('error')['text'])
            until('state')
            send(op='activate')
            prompt=until('prompt');self.assertEqual(prompt['kind'],'access')
            send(op='reply',id=prompt['id'],value='synthetic-invitation')
            while not until('state')['access']:pass
            send(op='login',email='synthetic',password='synthetic')
            for kind, answer in [('code','123456'),('phone',True),('certificates',None)]:
                prompt=until('prompt');self.assertEqual(prompt['kind'],kind)
                send(op='reply',id=prompt['id'],value=answer)
            self.assertEqual(until('status')['text'],'All prompts completed')
            while until('state')['busy']:pass
            send(op='shutdown');until('bye')
            self.assertEqual(p.wait(timeout=5),0)
        finally:
            if p.poll() is None:p.kill();p.wait()
            p.stdin.close();p.stdout.close();p.stderr.close()
