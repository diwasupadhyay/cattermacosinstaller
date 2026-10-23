"""Opt-in macOS metadata provider. Never accepts Apple login credentials.

Protocol: Omnisette v3. State lasts only for this setup process.
"""
import base64
from datetime import datetime, timezone
import hashlib
import json
import plistlib
import uuid
import sys
from urllib.parse import urlsplit

import requests

ORIGIN = 'https://mac-ani.jkcoxson.com'
LIMIT = 1024 * 1024


def value(data, key):
    result = data.get(key)
    if not isinstance(result, str) or not result or len(result) > 65536 or '\r' in result or '\n' in result:
        raise RuntimeError('Authentication metadata was invalid.')
    return result


def apple_url(url):
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or parsed.hostname != 'gsa.apple.com' or parsed.port not in (None, 443) or parsed.username or parsed.password or parsed.fragment:
        raise RuntimeError('Unexpected Apple provisioning endpoint.')
    return url


def request(url, *, payload=None, headers=None, apple=False):
    verify = True
    if apple:
        apple_url(url)
        from ipaside_engine import tls
        verify = tls.ca_bundle()
    elif url not in (ORIGIN + '/v3/client_info', ORIGIN + '/v3/get_headers'):
        raise RuntimeError('Unexpected metadata endpoint.')
    with requests.Session() as session:
        session.trust_env = False
        with session.request('POST' if payload is not None else 'GET', url, data=payload,
                             headers=headers, timeout=(15, 30), allow_redirects=False, stream=True, verify=verify) as response:
            if response.status_code != 200:
                raise RuntimeError(f'Authentication metadata service returned HTTP {response.status_code}.')
            result = bytearray()
            for chunk in response.iter_content(16384):
                result.extend(chunk)
                if len(result) > LIMIT:
                    raise RuntimeError('Authentication metadata response was too large.')
            return bytes(result)


class MacMetadata:
    def __init__(self):
        self.identifier = uuid.uuid4()
        self.blob = None
        self.info = None

    def _base(self):
        return {
            'X-MMe-Client-Info': value(self.info, 'client_info'),
            'User-Agent': value(self.info, 'user_agent'),
            'X-Mme-Device-Id': str(self.identifier).upper(),
            'X-Apple-I-MD-LU': base64.b64encode(hashlib.sha256(self.identifier.bytes).hexdigest().upper().encode()).decode(),
            'X-Apple-I-Client-Time': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'X-Apple-I-TimeZone': 'UTC', 'X-Apple-Locale': 'en_US', 'X-Apple-I-MD-RINFO': '17106176',
        }

    def _apple(self, url, body):
        headers = self._base()
        headers['Content-Type'] = 'text/x-xml-plist'
        result = plistlib.loads(request(apple_url(url), payload=plistlib.dumps({'Header': {}, 'Request': body}), headers=headers, apple=True))
        return result['Response']

    def _provision(self):
        from websockets.sync.client import connect
        lookup = plistlib.loads(request('https://gsa.apple.com/grandslam/GsService2/lookup', headers=self._base(), apple=True))['urls']
        start = apple_url(lookup['midStartProvisioning'])
        finish = apple_url(lookup['midFinishProvisioning'])
        spim = value(self._apple(start, {}), 'spim')
        with connect('wss://mac-ani.jkcoxson.com/v3/provisioning_session', proxy=None,
                     open_timeout=20, close_timeout=5, max_size=LIMIT) as socket:
            def receive(expected):
                message = json.loads(socket.recv(timeout=30))
                if message.get('result') != expected:
                    raise RuntimeError('Unexpected metadata provisioning response.')
                return message
            def send(body):
                socket.send(json.dumps(body))
            receive('GiveIdentifier')
            send({'identifier': base64.b64encode(self.identifier.bytes).decode()})
            receive('GiveStartProvisioningData')
            send({'spim': spim})
            cpim = value(receive('GiveEndProvisioningData'), 'cpim')
            end = self._apple(finish, {'cpim': cpim})
            send({'ptm': value(end, 'ptm'), 'tk': value(end, 'tk')})
            blob = value(receive('ProvisioningSuccess'), 'adi_pb')
            base64.b64decode(blob, validate=True)
            self.blob = blob

    def headers(self):
        try:
            if self.info is None:
                self.info = json.loads(request(ORIGIN + '/v3/client_info'))
                if 'Mac' not in value(self.info, 'client_info'):
                    raise RuntimeError('Expected a macOS metadata provider.')
            if self.blob is None:
                self._provision()
            payload = json.dumps({'identifier': base64.b64encode(self.identifier.bytes).decode(), 'adi_pb': self.blob}).encode()
            data = json.loads(request(ORIGIN + '/v3/get_headers', payload=payload, headers={'Content-Type': 'application/json'}))
            result = self._base()
            for key in ('X-Apple-I-MD', 'X-Apple-I-MD-M', 'X-Apple-I-MD-RINFO'):
                result[key] = value(data, key)
            for key in ('X-Apple-I-MD', 'X-Apple-I-MD-M'):
                base64.b64decode(result[key], validate=True)
            if not result['X-Apple-I-MD-RINFO'].isascii() or not result['X-Apple-I-MD-RINFO'].isdigit():
                raise RuntimeError('Invalid metadata routing information.')
            return result
        except Exception:
            # Third-party and Apple response bodies must never enter UI/logs.
            raise RuntimeError('macOS authentication metadata could not be prepared. No Apple sign-in was attempted by this provider.') from None


def enable(gsa, *, consent=False):
    if consent is not True or sys.platform not in ('win32', 'darwin'):
        raise RuntimeError('Remote metadata requires explicit consent for this setup session.')
    provider = MacMetadata()
    provider.info = json.loads(request(ORIGIN + '/v3/client_info'))
    if 'Mac' not in value(provider.info, 'client_info'):
        raise RuntimeError('Expected a macOS metadata provider.')
    agent = value(provider.info, 'user_agent')
    # Keep one provider for login AND provisioning; never mix device identities.
    gsa.anisette.get_headers = provider.headers
    gsa._GS_USER_AGENT = agent
    return provider
