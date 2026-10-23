"""Online setup authorization. Codes use OS credential storage; no owner secrets here."""
import json
from pathlib import Path
import re
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler


def valid_url(value):
    try:
        url = urlsplit(value)
        return (url.scheme == 'https' and bool(url.hostname) and not url.username
                and not url.password and not url.query and not url.fragment
                and url.path in ('', '/'))
    except ValueError:
        return False


class InvitationRejected(RuntimeError):
    pass


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def authorize(code, installer_device):
    if not re.fullmatch(r'[a-f0-9]{48}', code):
        raise RuntimeError('Paste the full Catter invitation code supplied by the owner.')
    if not re.fullmatch(r'[a-f0-9]{64}', installer_device):
        raise RuntimeError('Connect your assigned iPhone by USB before verifying access.')
    try:
        config = json.loads(Path(__file__).with_name('access-config.json').read_text(encoding='utf-8'))
        base = config['url']
        if not isinstance(base, str) or not valid_url(base):
            raise ValueError()
    except (OSError, ValueError, KeyError, TypeError):
        raise RuntimeError('This installer has no configured access service. Ask the owner for an updated installer.') from None
    request = Request(base.rstrip('/') + '/api/installer',
                      data=json.dumps({'code': code, 'installerDevice': installer_device}).encode(), method='POST',
                      headers={'Content-Type': 'application/json', 'User-Agent': 'CatterSetup/' + INSTALLER_VERSION})
    try:
        with build_opener(NoRedirects()).open(request, timeout=20) as response:
            if response.status != 200:
                raise RuntimeError('Access service returned an unexpected response.')
            result = json.loads(response.read(8193))
        remaining = result['expiresAt'] - result['serverTime']
        if not 0 < result['validFor'] <= min(60, remaining):
            raise ValueError()
        return result
    except HTTPError as error:
        if error.code == 403:
            raise InvitationRejected('Invitation is invalid, expired, revoked, or assigned to another iPhone. Use the assigned phone or contact the owner.') from None
        raise RuntimeError('Access could not be verified. Try again later.') from None
    except (URLError, OSError, ValueError, KeyError, TypeError):
        raise RuntimeError('Access could not be verified. Check your internet connection and retry.') from None


INSTALLER_VERSION = '0.11.0'
DOWNLOAD_URL = 'https://github.com/diwasupadhyay/catter/releases/latest'


def check_update(platform):
    """Public metadata only. No invitation, Apple account, or device ID sent."""
    config = json.loads(Path(__file__).with_name('access-config.json').read_text(encoding='utf-8'))
    base = config['url']
    if not valid_url(base):
        raise ValueError('Invalid update service')
    request = Request(base.rstrip('/') + '/api/releases', headers={'Accept': 'application/json', 'User-Agent': 'CatterSetup/' + INSTALLER_VERSION})
    with build_opener(NoRedirects()).open(request, timeout=10) as response:
        if response.status != 200:
            raise ValueError('Update service unavailable')
        data = response.read(16385)
    if len(data) > 16384:
        raise ValueError('Update response too large')
    result = json.loads(data)
    for release in result['releases']:
        version = release.get('version', '')
        if release.get('platform') == platform and isinstance(version, str) and re.fullmatch(r'[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}', version):
            if tuple(map(int, version.split('.'))) > tuple(map(int, INSTALLER_VERSION.split('.'))):
                return version
    return None
