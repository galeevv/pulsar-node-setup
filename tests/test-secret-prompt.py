#!/usr/bin/env python3
"""Verify the actual hidden terminal prompt, without installing anything."""
import os
from pathlib import Path
import pty
import select
import signal
import tempfile
import time

with tempfile.TemporaryDirectory() as temp:
    env = dict(os.environ, PULSAR_SETUP_DIR=temp+'/state', PULSAR_NODE_DIR=temp+'/node')
    script = str(Path(__file__).resolve().parents[1] / 'new-node.sh')
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe('bash', ['bash', '-c', 'source "$1"; read_secret; write_secret; echo PROMPT_OK', 'test', script], env)
    output = b''
    sent = False
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if select.select([fd], [], [], .2)[0]:
                try:
                    part = os.read(fd, 4096)
                except OSError:
                    break
                if not part:
                    break
                output += part
                if b'Secret Key (' in output and not sent:
                    os.write(fd, b'fixture-NOT-PRINTED-key==\n')
                    sent = True
            if b'PROMPT_OK' in output:
                break
        assert sent and b'PROMPT_OK' in output, output.decode(errors='replace')
        assert b'fixture-NOT-PRINTED-key' not in output
        content = Path(temp+'/node/.env').read_text()
        assert 'SECRET_KEY=fixture-NOT-PRINTED-key==' in content
        assert Path(temp+'/node/.env').stat().st_mode & 0o777 == 0o600
        print('PASS: real TTY prompt hides Secret Key and saves mode 600')
    finally:
        os.close(fd)
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
