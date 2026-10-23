"""Add an iOS Bonjour callback to the pinned MIT idevice host implementation.

Apple's NetService advertises the listener instead of a raw multicast socket.
Keep upstream authentication, cancellation and credential generation unchanged.
"""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / 'ffi/src/pairable_host.rs'
source = path.read_text(encoding='utf-8')
assert 'ghostly_pairable_host_accept' not in source, 'Patch already applied'
start = source.index('pub unsafe extern "C" fn pairable_host_accept_with_options(')
function = source[start:]
function = function.replace('pairable_host_accept_with_options(', 'ghostly_pairable_host_accept(', 1)
function = function.replace('    allows_pinless_pairing: bool,', '''    allows_pinless_pairing: bool,
    publish: extern "C" fn(u16, *const c_char, *const u8, usize, *mut c_void),''', 1)
a = function.index('        // Advertise the pairable-host')
b = function.index('        let pair = async', a)
function = function[:a] + '''        let txt = host_info.mdns_txt_records(&service_identifier);
        let values: plist::Dictionary = txt.into_iter()
            .map(|(k, v)| (k, plist::Value::String(v))).collect();
        let mut bytes = Vec::new();
        plist::to_writer_xml(&mut bytes, &values)?;
        let identifier = CString::new(service_identifier)
            .map_err(|_| IdeviceError::FfiInvalidString)?;
        publish(port, identifier.as_ptr(), bytes.as_ptr(), bytes.len(), ctx.0);

''' + function[b:]
a = function.index('        if let Ok(rx) = mdns.shutdown()')
b = function.index('        result.map(', a)
function = function[:a] + function[b:]
path.write_text(source + '\n#[unsafe(no_mangle)]\n' + function, encoding='utf-8')

# The older host-initiated iOS consent flow uses the same protocol implementation.
with path.open('a', encoding='utf-8') as out:
    out.write(r'''
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ghostly_pair_network(
    cancel: *const PairableHostCancel,
    out_pairing_file: *mut *mut RpPairingFileHandle,
) -> *mut IdeviceFfiError {
    if cancel.is_null() || out_pairing_file.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let cancel = unsafe { &*cancel }.0.clone();
    let result = run_sync_local(async move {
        let pair = async {
            let stream = tokio::net::TcpStream::connect(("10.7.0.1", 49152)).await
                .map_err(|e| IdeviceError::InternalError(format!("local pairing connect: {e}")))?;
            let mut client = idevice::remote_pairing::RemotePairingClient::new(
                RpPairingSocket::new(stream), "Catter");
            let mut file = RpPairingFile::generate("Catter");
            // iOS requests user consent; this is the protocol's fixed SRP PIN,
            // not a bypass of the user's consent or device passcode.
            client.connect(&mut file, async || "000000".to_string()).await?;
            Ok::<_, IdeviceError>(file)
        };
        tokio::select! {
            biased;
            _ = cancel.canceled() => Err(IdeviceError::CanceledByUser),
            r = tokio::time::timeout(Duration::from_secs(90), pair) =>
                r.unwrap_or_else(|_| Err(IdeviceError::InternalError("Pairing approval timed out".into()))),
        }
    });
    match result {
        Ok(file) => {
            unsafe { *out_pairing_file = Box::into_raw(Box::new(RpPairingFileHandle(file))); }
            null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}
''')
