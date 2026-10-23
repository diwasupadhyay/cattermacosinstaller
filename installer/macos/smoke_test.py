"""No Apple login or USB writes: validate the shipped Mac interpreter and IPC."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(root))
from pymobiledevice3.services.mobile_image_mounter import auto_mount
from ipaside_engine import device, signing, gsa
assert Path(signing.resolve_zsign()).is_file()
assert (root / 'native/idevice-tools').is_file()
assert (root / 'native/catter-local-metadata').is_file()
assert (root / 'remote_anisette.py').is_file()
from local_macos_metadata import enable
provider = enable(gsa)
assert callable(gsa.anisette.get_headers)
with tempfile.TemporaryDirectory() as private:
    environment = dict(os.environ, LOCALAPPDATA=private)
    result = subprocess.run([str(root / 'runtime/bin/python3'), '-B', '-E', '-X', 'utf8', str(root / 'backend.py')],
                            input='{"op":"shutdown"}\n', text=True, capture_output=True,
                            timeout=40, env=environment)
    if result.returncode:
        raise RuntimeError('Backend startup failed: ' + result.stderr[-2000:])
    messages = [json.loads(line) for line in result.stdout.splitlines()]
    assert messages[0]['type'] == 'state' and not messages[0]['authenticated']
    assert messages[-1]['type'] == 'bye'
    folder = Path(private) / 'CatterInstaller'
    assert folder.stat().st_mode & 0o777 == 0o700
    assert not any(p.is_file() for p in (folder / 'session').rglob('*'))
print('Mac runtime, signing imports, private permissions and account shutdown passed.')
