"""Scoped recovery for Apple's certificate limit; never revoke without consent."""
from contextlib import contextmanager


@contextmanager
def certificate_recovery(api, choose, confirm):
    original = api.submit_csr
    original_revoke = api.revoke_certificate
    attempted = False

    def revoke(team_id, serial):
        # Upstream provisioning can revoke an older matching-machine certificate
        # before submitting a CSR. That path must also require explicit consent.
        selected = next((c for c in api.list_certificates(team_id)
                         if c.get('serialNumber') == serial), None)
        if selected is None or not confirm(selected):
            raise RuntimeError('Certificate replacement cancelled. No certificate was revoked.')
        return original_revoke(team_id, serial)

    def submit(team_id, csr_pem, machine_name='CatterInstaller'):
        nonlocal attempted
        try:
            return original(team_id, csr_pem, machine_name=machine_name)
        except api.DeveloperServicesError as error:
            if not str(error).startswith('7460:') or attempted:
                raise
            attempted = True
            certificates = [c for c in api.list_certificates(team_id) if c.get('serialNumber')]
            if not certificates:
                raise RuntimeError('Apple reports a certificate limit or pending request, but returned no replaceable development certificates. No certificates were changed.') from error
            serial = choose(certificates)
            selected = next((c for c in certificates if c['serialNumber'] == serial), None)
            if selected is None or not confirm(selected):
                raise RuntimeError('Certificate replacement cancelled. No certificate was revoked.') from error
            # Re-check the exact team and serial after the user has made their decision.
            if not any(c.get('serialNumber') == serial for c in api.list_certificates(team_id)):
                raise RuntimeError('That certificate changed while you were choosing. Retry installation.')
            original_revoke(team_id, serial)
            try:
                return original(team_id, csr_pem, machine_name=machine_name)
            except Exception as retry_error:
                raise RuntimeError('The selected certificate was revoked, but Apple did not issue its replacement. Apps signed with the old certificate may need reinstalling. Apple reported: ' + str(retry_error)) from retry_error

    api.submit_csr = submit
    api.revoke_certificate = revoke
    try:
        yield
    finally:
        api.submit_csr = original
        api.revoke_certificate = original_revoke
