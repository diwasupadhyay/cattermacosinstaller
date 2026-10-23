"""Reject build-machine dylibs in this statically linked, device-only app."""
import subprocess
import sys

binary = sys.argv[1]
output = subprocess.check_output(['otool', '-L', binary], text=True)
dependencies = [line.strip().split(' (', 1)[0] for line in output.splitlines()[1:] if line.strip()]
bad = [path for path in dependencies if not path.startswith(('/System/Library/', '/usr/lib/'))]
if bad:
    raise SystemExit('Unbundled runtime dependencies: ' + ', '.join(bad))
symbols = subprocess.check_output(['nm', '-g', binary], text=True)
for symbol in ('_tunnel_create_rppairing', '_location_simulation_set', '_location_simulation_clear', '_ghostly_pair_network', '_ghostly_pairable_host_accept', '_cryptexd_install_ddi', '_image_mounter_mount_personalized_rsd'):
    if not any(line.split()[-2:] == ['T', symbol] for line in symbols.splitlines()):
        raise SystemExit('Missing statically linked transport symbol: ' + symbol)
print('Runtime dependencies and static transport symbols verified.')
