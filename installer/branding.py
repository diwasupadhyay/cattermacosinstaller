"""Product identity and compatibility with installations made before the rename."""
from pathlib import Path

PRODUCT_NAME = 'Catter'
SIGNING_NAME = 'CatterInstaller'


def storage_namespace(local_app_data):
    # Reuse private signing material and pairing backups without copying secrets.
    # New users get a Catter directory; established users retain their old path.
    legacy = Path(local_app_data) / 'GhostlyInstaller'
    return 'GhostlyInstaller' if legacy.exists() else SIGNING_NAME
