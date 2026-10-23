"""Fetch pinned renewal sources and apply Catter's reproducible privacy patches.

The generated Vendor tree belongs in corresponding-source release materials,
not in a credential directory. Never resolve moving dependency branches.
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PINS = {
    'SideSign': ('SideStore/SideSign', '752d1ef602aa792a432ffa1e71646dc1ecf7363c'),
    'CodeSignKit': ('mahee96/CodeSignKit', 'd0c67710fda9a2646b9e829cb2cf443892728371'),
    'GSACryptoKit': ('mahee96/GSACryptoKit', 'eae2590eaf17fe98ce9c76b3ec2bd42b780eb123'),
    'AnisetteKit': ('mahee96/AnisetteKit', 'db8b41022697b6c19be8a5f01a1ce834145a2a26'),
    'libdeflate': ('SideStore/libdeflate', 'da6c7dae03b78dc71af973664575e4209786fbfe'),
}


def prepare():
    for name, (repo, revision) in PINS.items():
        folder = ROOT / 'Vendor' / name
        if folder.exists():
            raise RuntimeError(f'{name} already exists; use a clean checkout for a reproducible build.')
        folder.mkdir(parents=True)
        for args in [('init',), ('remote', 'add', 'origin', 'https://github.com/' + repo + '.git'),
                     ('fetch', '--depth', '1', 'origin', revision), ('checkout', '--detach', 'FETCH_HEAD')]:
            subprocess.run(['git', '-C', str(folder), *args], check=True)
        actual = subprocess.check_output(['git', '-C', str(folder), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != revision:
            raise RuntimeError('Renewal dependency revision mismatch: ' + name)

    folder = ROOT / 'Vendor/SideSign'
    package = folder / 'Package.swift'
    text = package.read_text()
    for name, (repo, revision) in PINS.items():
        if name == 'SideSign':
            continue
        pattern = r'\.package\(url: "https://github.com/' + re.escape(repo) + r'(?:\.git)?",\s+branch: "(?:main|master)"\)'
        text, count = re.subn(pattern, '.package(path: "../' + name + '")', text)
        if count != 1:
            raise RuntimeError('Pinned package declaration changed: ' + name)
    package.write_text(text)

    # Upstream debugLog prints regardless of setLogging(false), and errors may
    # contain full Apple response payloads. Disable both without evaluating the
    # autoclosure, so secrets never reach console or diagnostic files.
    logging = folder / 'Sources/Logging.swift'
    text = logging.read_text()
    for function in ('debugLog', 'verboseLog'):
        pattern = r'public func ' + function + r'\(_ text: @autoclosure \(\) -> String\) \{.*?\n\}'
        text, count = re.subn(pattern, 'public func ' + function + '(_ text: @autoclosure () -> String) {}', text, flags=re.S)
        if count != 1:
            raise RuntimeError('Pinned logging implementation changed: ' + function)
    logging.write_text(text)

    logging = ROOT / 'Vendor/AnisetteKit/Sources/AnisetteKitLogging.swift'
    text = logging.read_text()
    for function in ('debugLog', 'verboseLog'):
        pattern = r'public func ' + function + r'\(_ text: @autoclosure \(\) -> String\) \{.*?\n\}'
        text, count = re.subn(pattern, 'public func ' + function + '(_ text: @autoclosure () -> String) {}', text, flags=re.S)
        if count != 1:
            raise RuntimeError('Pinned anisette logging changed: ' + function)
    logging.write_text(text)

    # Never permit a downloaded authentication library with a mismatched digest.
    manager = folder / 'Sources/Anisette/AnisetteDataManager.swift'
    text = manager.read_text()
    pattern = r'debugLog\("\[AnisetteDataManager\] SHA-256 mismatch .*?Proceeding with extraction\."\)'
    text, count = re.subn(pattern, 'throw AnisetteError.sha256Mismatch(expected: expectedSHA, actual: zipSHA)', text)
    if count != 1:
        raise RuntimeError('Pinned digest verification changed.')
    manager.write_text(text)


if __name__ == '__main__':
    prepare()
