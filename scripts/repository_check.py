"""Check publishable tracked files without printing potential secret values."""
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    'private-key block': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'GitHub token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b'),
    'AWS access key': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'Slack token': re.compile(rb'\bxox[baprs]-[A-Za-z0-9-]{20,}\b'),
}
FORBIDDEN = {'.ipa', '.exe', '.dmg', '.pkg', '.zip', '.p12', '.pfx', '.key', '.pem',
             '.mobileprovision', '.mobiledevicepairing', '.pcap', '.pcapng', '.log'}
PRIVATE_PARTS = {'build', 'vendor', '.git', '.device-setup', 'device-private', 'backups', '__pycache__',
                 'node_modules', '.wrangler'}


def tracked():
    result = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT)
    return [Path(name.decode('utf-8')) for name in result.split(b'\0') if name]


def issues_for(path, data):
    errors = []
    if path.suffix.lower() == '.md' and path != Path('README.md') and path.parts[0] != 'docs':
        errors.append('Markdown documentation belongs in docs/')
    if any(part.lower() in PRIVATE_PARTS for part in path.parts) or path.suffix.lower() in FORBIDDEN:
        errors.append('private/generated file is tracked')
    if path.name.startswith('.env') and path.name != '.env.example':
        errors.append('environment file is tracked')
    if path.name.startswith('.dev.vars') or path.name == 'access-config.json':
        errors.append('local access configuration is tracked')
    if path.suffix == '.plist' and 'pairing' in path.name.lower():
        errors.append('pairing record is tracked')
    for name, pattern in PATTERNS.items():
        if pattern.search(data):
            errors.append(name)
    return errors


def check():
    errors = []
    paths = [path for path in tracked() if (ROOT / path).exists()]
    for path in paths:
        absolute = ROOT / path
        if absolute.is_symlink() or not absolute.resolve().is_relative_to(ROOT):
            errors.append((path, 'linked file is not allowed in source export'))
            continue
        data = absolute.read_bytes()
        errors.extend((path, reason) for reason in issues_for(path, data))
        if path.suffix == '.md':
            text = data.decode('utf-8')
            links = re.findall(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)', text)
            links += re.findall(r'(?:src|href)="([^"]+)"', text)
            for target in links:
                if target.startswith(('#', 'https://', 'http://', 'mailto:')):
                    continue
                target = unquote(target.split('#')[0])
                if not (absolute.parent / target).exists():
                    errors.append((path, 'broken relative link: ' + target))
    for path, reason in errors:
        print(f'{path.as_posix()}: {reason}')  # Never print matched secret text.
    if errors:
        raise SystemExit(1)
    print(f'Checked {len(paths)} tracked files: no blocked paths, token/key-pattern matches or broken Markdown links.')
    print('This is a targeted check, not proof that all secrets or vulnerabilities are absent.')


if __name__ == '__main__':
    check()
