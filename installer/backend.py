"""Private JSON-lines IPC. Credentials travel only over inherited anonymous pipes."""
import json
import queue
import sys
import threading
import time
import uuid

# Keep signed macOS bundles read-only, including imports in worker threads.
sys.dont_write_bytecode = True
from service import InstallerService


def main():
    if sys.platform == 'darwin':
        import os
        # Foundation Process may already create a process group with our PID.
        # setsid() fails with EPERM for a group leader. Either arrangement
        # provides the isolated group the native UI needs for cancellation.
        if os.getpgrp() != os.getpid():
            os.setsid()
        if os.getpgrp() != os.getpid():
            raise RuntimeError('Could not isolate the setup process group.')
    output = sys.stdout
    # Third-party progress output must never become protocol or UI log content.
    sys.stdout = sys.stderr
    lock = threading.Lock()
    commands = queue.Queue()
    prompts = {}

    def send(message_type, **values):
        with lock:
            output.write(json.dumps(dict(type=message_type, **values)) + '\n')
            output.flush()

    def read():
        try:
            for line in sys.stdin:
                try:
                    value = json.loads(line)
                    if isinstance(value, dict):
                        commands.put(value)
                except ValueError:
                    pass
        finally:
            commands.put({'op': 'eof'})

    app = InstallerService()

    def state():
        from ipaside_engine import gsa
        account = gsa.status()
        send('state', busy=app.working, authenticated=bool(account.get('authenticated')),
             email=account.get('email') or '', ipa=bool(app.ipa), access=bool(app.access_code))

    threading.Thread(target=read, daemon=True).start()
    state()
    restore_pending = True
    next_access_check = time.monotonic() + 2
    update_lock = threading.Lock()
    def updates():
        if not update_lock.acquire(blocking=False): return
        try:
            from access import check_update
            version = check_update('macos' if sys.platform == 'darwin' else 'windows')
            send('update', version=version or '', text=('Catter Setup ' + version + ' is available.') if version else 'Catter Setup is up to date.')
        except Exception:
            send('update', version='', text='Could not check for updates. You can continue setup and try again later.')
        finally:
            update_lock.release()
    threading.Thread(target=updates, daemon=True).start()
    try:
        while True:
            try:
                command = commands.get(timeout=0.05)
            except queue.Empty:
                command = {}
            if not command.get('op') and time.monotonic() >= next_access_check and not app.working:
                next_access_check = time.monotonic() + 45
                if hasattr(app, 'expire_saved_session'):
                    app.expire_saved_session()
                    state()
                if (app.access_code or restore_pending) and hasattr(app, 'restore_access'):
                    restore_pending = False
                    app.work(app.restore_access)
                    state()
            op = command.get('op')
            if op == 'eof':
                break
            try:
                if op == 'updates':
                    threading.Thread(target=updates, daemon=True).start()
                    continue
                if op == 'reply':
                    pending = prompts.pop(command.get('id'), None)
                    if pending:
                        answer, ready = pending
                        answer.append(command.get('value'))
                        ready.set()
                elif op:
                    if app.working:
                        raise RuntimeError('Wait for the current operation to finish.')
                    if op == 'shutdown':
                        app.close()
                        send('bye')
                        break
                    if op == 'activate':
                        app.work(app.require_access)
                    elif op not in ('logout',) and not app.access_code:
                        raise RuntimeError('Verify your Catter invitation before continuing.')
                    elif op == 'login':
                        app.sign_in(str(command.get('email', '')), str(command.get('password', '')))
                    elif op == 'select':
                        info = app.select_ipa(command['path'])
                        send('ipa', name='Catter ' + str(info['CFBundleShortVersionString']),
                             build=str(info['CFBundleVersion']), path=command['path'])
                    elif op == 'install':
                        app.install()
                    elif op == 'prepare':
                        app.prepare()
                    elif op == 'logout':
                        app.forget()
                    state()
            except Exception as error:
                send('error', text=str(error))
                state()
            finally:
                command.clear()
            while not app.events.empty():
                kind, value = app.events.get_nowait()
                if kind in ('status', 'error'):
                    send(kind, text=value)
                elif kind == 'finished':
                    app.working = False
                    state()
                elif kind == 'signed_out':
                    send('signed_out')
                elif kind in ('code', 'access', 'phone', 'certificates'):
                    identifier = uuid.uuid4().hex
                    if kind == 'phone':
                        title, text, answer, ready = value
                        data = dict(title=title, text=text)
                    elif kind in ('code', 'access'):
                        text, answer, ready = value
                        data = dict(title='Activate Catter setup' if kind == 'access' else 'Verify your Apple Account', text=text)
                    else:
                        certificates, answer, ready = value
                        data = dict(title='Choose a certificate to replace', certificates=certificates,
                                    text='Replacing a certificate may stop other sideloaded apps from opening. Choose one to review, or cancel.')
                    prompts[identifier] = (answer, ready)
                    send('prompt', id=identifier, kind=kind, **data)
    finally:
        for answer, ready in prompts.values():
            answer.append(None)
            ready.set()
        app.close()


if __name__ == '__main__':
    main()
