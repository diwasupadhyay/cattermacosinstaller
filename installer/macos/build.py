"""Build a relocatable native macOS .app with pinned, verified runtime downloads."""
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
ARCH = platform.machine()
if ARCH not in ('arm64', 'x86_64'):
    raise SystemExit('Build on an Apple Silicon or Intel Mac.')
CPU = 'aarch64' if ARCH == 'arm64' else 'x86_64'
NATIVE_CPU = 'arm' if ARCH == 'arm64' else 'intel'
PYTHON_HASH = {
    'arm64': 'ba32036ad8f4c434d97a1ee7feef8b7edc0fac16777639b97e39c74a108e4440',
    'x86_64': '9686ddd8639b855905447ea4a16eb54a804a9ef12afbe7c9ecb1412d9c1fbc98',
}[ARCH]
NATIVE_HASH = {
    'arm64': 'fc4c2a74a3d2899bc33a7c2ed42d367e843b9dd6854bb3b1b257274b1ce712fa',
    'x86_64': 'ba27ffd646a06ac411e185607343a8e8da437d1fa52a24a2d7c6411d4d8d1447',
}[ARCH]
output = ROOT / 'build' / ('macos-' + ARCH)
app = output / 'Catter Setup.app'
resources = app / 'Contents' / 'Resources'
backend = resources / 'backend'
backend.mkdir(parents=True, exist_ok=False)
(app / 'Contents' / 'MacOS').mkdir()


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def download(url, filename, digest):
    path = output / filename
    urllib.request.urlretrieve(url, path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise RuntimeError('Download checksum mismatch: ' + filename)
    return path


runtime = download(
    f'https://github.com/astral-sh/python-build-standalone/releases/download/20261013/'
    f'cpython-3.12.15%2B20261013-{CPU}-apple-darwin-install_only.tar.gz',
    'python.tar.gz', PYTHON_HASH)
with tarfile.open(runtime) as archive:
    archive.extractall(output / 'runtime-unpack', filter='data')
shutil.move(output / 'runtime-unpack' / 'python', backend / 'runtime')
python = backend / 'runtime' / 'bin' / 'python3'
site = backend / 'runtime' / 'lib' / 'python3.12' / 'site-packages'
run(python, '-m', 'pip', 'install', '--disable-pip-version-check',
    'websockets==15.0.1', 'keyring==25.6.0', '-r', ROOT / 'Vendor/iPASide/src/iPASide.Engine/requirements.txt',
    'git+https://github.com/doronz88/pymobiledevice3.git@8e2be44e6a97edaa67a6812a806f24965ad181c9')
shutil.copytree(ROOT / 'Vendor/iPASide/src/iPASide.Engine/ipaside_engine', site / 'ipaside_engine')
engine = site / 'ipaside_engine'
for filename, before, after in [
    ('paths.py', 'APP_NAME = "iPASide"', 'APP_NAME = "CatterInstaller"'),
    ('provision.py', 'CERTIFICATE_MACHINE_NAME = "iPASide"', 'CERTIFICATE_MACHINE_NAME = "CatterInstaller"'),
]:
    path = engine / filename
    text = path.read_text()
    if text.count(before) != 1:
        raise RuntimeError('Pinned namespace patch no longer matches.')
    path.write_text(text.replace(before, after))

# Link OpenSSL statically so the user needs neither Homebrew nor its library path.
openssl = Path(subprocess.check_output(['brew', '--prefix', 'openssl@3'], text=True).strip())
run('make', '-C', ROOT / 'Vendor/zsign/build/macos', '-j4',
    f'OPENSSL_INCLUDE=-I{openssl}/include',
    f'OPENSSL_LIB={openssl}/lib/libssl.a {openssl}/lib/libcrypto.a',
    'VERSION=Catter')
(engine / 'vendor').mkdir(exist_ok=True)
shutil.copy2(ROOT / 'Vendor/zsign/bin/zsign', engine / 'vendor/zsign')

native = download(f'https://github.com/jkcoxson/idevice/releases/download/v0.1.68/'
                  f'idevice-tools-macos-{NATIVE_CPU}-v0.1.68.zip', 'native.zip', NATIVE_HASH)
with zipfile.ZipFile(native) as archive:
    archive.extractall(output / 'native-unpack')
candidates = list((output / 'native-unpack').rglob('idevice-tools'))
if len(candidates) != 1:
    raise RuntimeError('Expected exactly one native developer tool.')
(backend / 'native').mkdir()
shutil.copy2(candidates[0], backend / 'native/idevice-tools')
(backend / 'native/idevice-tools').chmod(0o755)

run('clang', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'IOKit',
    '-mmacosx-version-min=13.0', ROOT / 'installer/macos/LocalMetadata.m',
    '-o', backend / 'native/catter-local-metadata')

for name in ('backend.py', 'service.py', 'access.py', 'branding.py', 'core.py', 'account_security.py', 'certificates.py', 'renewal.py', 'local_macos_metadata.py', 'remote_anisette.py', 'invitation_store.py'):
    shutil.copy2(ROOT / 'installer' / name, backend / name)
run(sys.executable, ROOT / 'scripts/configure_access.py', backend)
(backend / 'scripts').mkdir()
shutil.copy2(ROOT / 'scripts/prepare_device.py', backend / 'scripts/prepare_device.py')
shutil.copy2(ROOT / 'Branding/Catter.png', resources / 'Catter.png')
shutil.copy2(ROOT / 'README.md', resources / 'README.md')
shutil.copytree(ROOT / 'Licenses', resources / 'Licenses')
shutil.copytree(ROOT / 'docs', resources / 'docs')
shutil.copytree(ROOT / 'Branding', resources / 'Branding')
shutil.copy2(ROOT / 'LICENSE', resources / 'LICENSE')
for name, path in [('iPASide', 'Vendor/iPASide/LICENSE'), ('zsign', 'Vendor/zsign/LICENSE'), ('Catter', 'LICENSE')]:
    shutil.copy2(ROOT / path, resources / 'Licenses' / (name + '.txt'))

iconset = output / 'Catter.iconset'
iconset.mkdir()
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        run('sips', '-z', size * scale, size * scale, ROOT / 'Branding/Catter.png',
            '--out', iconset / f'icon_{size}x{size}{suffix}.png', stdout=subprocess.DEVNULL)
run('iconutil', '-c', 'icns', iconset, '-o', resources / 'Catter.icns')
with (app / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump({
        'CFBundleIdentifier': 'com.diwasupadhyay.catter.setup',
        'CFBundleName': 'Catter Setup', 'CFBundleDisplayName': 'Catter Setup',
        'CFBundleExecutable': 'CatterSetup', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '0.11.1', 'CFBundleVersion': '33',
        'CFBundleIconFile': 'Catter.icns', 'LSMinimumSystemVersion': '13.0',
        'NSHighResolutionCapable': True,
        'NSLocalNetworkUsageDescription': 'Connect to your iPhone to install and prepare Catter.',
    }, stream)
run('swiftc', '-parse-as-library', '-swift-version', '5', '-O',
    '-target', f'{ARCH}-apple-macosx13.0',
    ROOT / 'installer/macos/CatterSetup.swift', '-o', app / 'Contents/MacOS/CatterSetup')
run(python, '-E', '-X', 'utf8', ROOT / 'installer/macos/smoke_test.py', backend)
run(python, '-E', '-X', 'utf8', '-m', 'unittest', 'discover', '-s', ROOT / 'installer/tests', '-v')

# Fail if either standalone helper still depends on the build machine's paths.
for binary in (engine / 'vendor/zsign', backend / 'native/idevice-tools', backend / 'native/catter-local-metadata'):
    linked = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    for line in linked.splitlines()[1:]:
        dependency = line.strip().split(' (')[0]
        if not dependency.startswith(('/usr/lib/', '/System/Library/')):
            raise RuntimeError('Unbundled helper dependency: ' + dependency)
    run('codesign', '--force', '--sign', '-', binary)
# Python must never write bytecode into a signed application bundle.
# Remove generated caches before sealing; the launcher uses -B.
for cache in list(backend.rglob('__pycache__')):
    shutil.rmtree(cache)
run('codesign', '--force', '--deep', '--sign', '-', app)
run('codesign', '--verify', '--deep', '--strict', app)
run(app / 'Contents/MacOS/CatterSetup', '--smoke')
run(app / 'Contents/MacOS/CatterSetup', '--backend-smoke')
artifact = output / ('CatterSetup-macOS-' + ARCH + '.zip')
run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, artifact)
# Validate the actual distributed archive after relocation (including spaces).
relocated = output / 'relocated test'
run('ditto', '-x', '-k', artifact, relocated)
relocated_app = relocated / app.name
run('codesign', '--verify', '--deep', '--strict', relocated_app)
run(relocated_app / 'Contents/MacOS/CatterSetup', '--backend-smoke')
run('codesign', '--verify', '--deep', '--strict', relocated_app)
(output / 'SHA256.txt').write_text(hashlib.sha256(artifact.read_bytes()).hexdigest() + '  ' + artifact.name + '\n')
(output / 'BUILD.txt').write_text(subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True) +
                                  platform.platform() + '\n')
with (output / 'DEPENDENCIES.txt').open('w') as stream:
    run(python, '-m', 'pip', 'freeze', stdout=stream)
print('Ready:', artifact)
