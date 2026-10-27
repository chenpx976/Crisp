#!/usr/bin/env python3
"""One pre-approved, self-contained standby/wake test. No mid-test tool approvals.

Keep the remote available. A TV with network wake disabled may need manual power-on.
This does not suspend the Mac and leaves automatic power sync disabled.
"""
import argparse
import json
import os
import socket
import stat
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('display', type=int)
args = parser.parse_args()
path = os.path.join(tempfile.gettempdir(), 'crispctl.sock')
info = os.lstat(path)
if info.st_uid != os.getuid() or not stat.S_ISSOCK(info.st_mode):
    raise SystemExit('Untrusted Crisp socket')


def request(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(65)
        client.connect(path)
        client.sendall(json.dumps({'command': 'webos.' + command, 'display': args.display}).encode() + b'\n')
        data = b''
        while b'\n' not in data:
            chunk = client.recv(4096)
            if not chunk:
                raise RuntimeError('Crisp closed before responding')
            data += chunk
            if len(data) > 65536:
                raise RuntimeError('Response too large')
    result = json.loads(data.split(b'\n', 1)[0])
    print(command + ': ' + json.dumps(result, ensure_ascii=False), flush=True)
    if not result.get('ok'):
        raise RuntimeError(result.get('error', command + ' failed'))
    return result


baseline = request('refresh')
prefs = baseline.get('preferences', {})
device = baseline.get('device', {})
if not baseline.get('ready') or device.get('power') != 'Active':
    raise SystemExit('TV must be on and connected before testing')
if device.get('currentInput') != prefs.get('macInput') or not prefs.get('wakeMACs'):
    raise SystemExit('Verify Mac HDMI input and wake MAC addresses first')
if prefs.get('powerSync'):
    raise SystemExit('Disable automatic power sync before testing')
# Exercise the full recovery command while the only display is still visible.
request('wake')
print('TV will enter standby in 5 seconds. No further approval is needed during this script.', flush=True)
time.sleep(5)
try:
    request('standby')
    time.sleep(3)
finally:
    # This runs even if standby acknowledgement fails or the socket closes.
    request('wake')
final = request('refresh')
if final.get('device', {}).get('power') != 'Active':
    raise SystemExit('TV active state was not confirmed; use the remote to turn it on')
print('PASS: TV is active again; automatic power sync remains disabled.', flush=True)
