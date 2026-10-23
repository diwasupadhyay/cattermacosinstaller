"""Add error-stage context to pinned idevice; never log pairing payloads/keys."""
from pathlib import Path
import sys


def patch(source):
    replacements = [
        ('let tunnel_port = rpc.create_tcp_listener().await?;',
         'let tunnel_port = rpc.create_tcp_listener().await.map_err(|e| IdeviceError::InternalError(format!("Request tunnel listener: {e}")))?;'),
        ('format!("TLS tunnel: {e}")', 'format!("Connect tunnel listener {tunnel_addr}: {e}")'),
        ('let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key()).await?;',
         'let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key()).await.map_err(|e| IdeviceError::InternalError(format!("TLS tunnel handshake: {e}")))?;'),
        ('let handshake = RsdHandshake::new(rsd_stream).await?;',
         'let handshake = RsdHandshake::new(rsd_stream).await.map_err(|e| IdeviceError::InternalError(format!("RSD handshake: {e}")))?;'),
    ]
    # Restrict replacements to the shared tunnel helper, not unrelated USB paths.
    start = source.index('async fn finish_tunnel(')
    end = source.index('\nfn write_result(', start)
    helper = source[start:end]
    for old, new in replacements:
        if helper.count(old) != 1:
            raise ValueError(f'Pinned tunnel helper changed: {old}')
        helper = helper.replace(old, new, 1)
    old = '.connect(rsd_port)\n        .await\n        .map_err(|e| IdeviceError::InternalError(format!("{e}")))?;'
    if helper.count(old) != 1:
        raise ValueError('Pinned RSD connection changed')
    helper = helper.replace(old, old.replace('format!("{e}")', 'format!("Connect RSD service: {e}")'), 1)
    source = source[:start] + helper + source[end:]
    start = source.index('pub unsafe extern "C" fn tunnel_create_rppairing(')
    end = source.index('\n/// Pairs with a device', start)
    function = source[start:end]
    old = 'format!("connect: {e}")'
    if function.count(old) != 1:
        raise ValueError('Pinned control connection changed')
    function = function.replace(old, 'format!("Connect pairing control {socket_addr}: {e}")', 1)
    old = 'rpc.connect(rpf, async || get_pin(pin_callback, &ctx))\n            .await?;'
    if function.count(old) != 1:
        raise ValueError('Pinned pairing handshake changed')
    function = function.replace(old, 'rpc.connect(rpf, async || get_pin(pin_callback, &ctx))\n            .await.map_err(|e| IdeviceError::InternalError(format!("Remote pairing handshake: {e}")))?;', 1)
    return (source[:start] + function + source[end:]).replace("{e}", "{e:?}")


if __name__ == '__main__':
    path = Path(sys.argv[1]) / 'ffi/src/tunnel_provider.rs'
    path.write_text(patch(path.read_text(encoding='utf-8')), encoding='utf-8')
