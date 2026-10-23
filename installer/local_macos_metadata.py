"""Use this Mac's AOSKit through a bounded subprocess; never use a server."""
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid


class LocalMetadataError(RuntimeError):
    """Local helper failure; eligible for a separately consented fallback."""


class LocalMacMetadata:
    def headers(self):
        if sys.platform != 'darwin':
            raise RuntimeError('Native Mac authentication is available only on macOS.')
        helper = Path(__file__).resolve().parent / 'native' / 'catter-local-metadata'
        try:
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith(('IPASIDE_', 'DYLD_'))}
            result = subprocess.run([str(helper)], capture_output=True, timeout=20, check=True, env=environment)
            if len(result.stdout) > 65536:
                raise ValueError('Oversized response')
            data = json.loads(result.stdout)
            for key in ('otp', 'machine', 'identifier', 'client', 'user_agent'):
                if not isinstance(data.get(key), str) or not data[key] or len(data[key]) > 16384 or not data[key].isascii() or '\r' in data[key] or '\n' in data[key]:
                    raise ValueError('Invalid metadata')
            for key in ('otp', 'machine'):
                base64.b64decode(data[key], validate=True)
            uuid.UUID(data['identifier'])  # Validate without rewriting the native identity.
            identifier = data['identifier']
            if '<macOS;' not in data['client'] or 'Windows' in data['client'] or 'Darwin/' not in data['user_agent']:
                raise ValueError('Unexpected platform')
            return {
                'X-MMe-Client-Info': data['client'],
                'User-Agent': data['user_agent'],
                'X-Mme-Device-Id': identifier,
                # Native AOSKit uses the identifier bytes, not the v3 server hash.
                'X-Apple-I-MD-LU': base64.b64encode(identifier.encode('utf-8')).decode(),
                'X-Apple-I-MD': data['otp'], 'X-Apple-I-MD-M': data['machine'],
                'X-Apple-I-MD-RINFO': '17106176',
                'X-Apple-I-Client-Time': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                'X-Apple-I-TimeZone': 'UTC', 'X-Apple-Locale': 'en_US',
            }
        except Exception as error:
            # Fixed diagnostic labels only: never display helper stdout/stderr,
            # exception strings or authentication metadata.
            if isinstance(error, subprocess.CalledProcessError):
                detail = {
                    2: 'M02: The system authentication framework or method is unavailable.',
                    3: 'M03: The system authentication service returned no usable metadata.',
                    4: 'M04: The local Mac identity could not be read.',
                    5: 'M05: The helper could not encode its response.',
                    6: 'M06: The system framework raised an exception.',
                }.get(error.returncode, 'M07: The local metadata helper terminated unexpectedly.')
            elif isinstance(error, subprocess.TimeoutExpired):
                detail = 'M08: The local authentication service did not respond within 20 seconds.'
            elif isinstance(error, OSError):
                detail = 'M09: The bundled metadata helper could not be started.'
            else:
                detail = 'M10: The helper returned metadata that failed validation.'
            raise LocalMetadataError('This Mac could not supply local Apple authentication metadata. '
                               + detail + ' No remote metadata provider was contacted. '
                               'Keep the installed app; do not revoke certificates or disable macOS security protections.') from None


def enable(gsa):
    provider = LocalMacMetadata()
    def headers():
        result = provider.headers()
        # GSA builds its own User-Agent independently of anisette headers.
        gsa._GS_USER_AGENT = result['User-Agent']
        return result
    gsa.anisette.get_headers = headers
    return provider
