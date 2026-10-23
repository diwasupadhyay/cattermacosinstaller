"""Write the public API URL into a desktop build; never include an owner key."""
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'installer'))
from access import valid_url

url = os.environ.get('CATTER_ACCESS_URL', '').strip()
if not valid_url(url):
    raise SystemExit('Set CATTER_ACCESS_URL to your deployed HTTPS Worker origin before building installers.')
destination = Path(sys.argv[1])
(destination / 'access-config.json').write_text(json.dumps({'url': url}) + '\n', encoding='utf-8')
