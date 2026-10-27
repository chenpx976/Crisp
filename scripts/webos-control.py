#!/usr/bin/env python3
"""LG network TV commands for the local Crisp development build."""
import argparse
import json
import os
import socket
import stat
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('command', choices=['connect', 'status', 'volume', 'disconnect', 'enable', 'enable-settings', 'refresh', 'brightness', 'input', 'wake', 'standby', 'config'])
parser.add_argument('display', type=int)
parser.add_argument('value', nargs='?')
parser.add_argument('--mac-input')
parser.add_argument('--mac-address')
parser.add_argument('--power-sync', choices=['true', 'false'])
parser.add_argument('--switch-on-wake', choices=['true', 'false'])
args = parser.parse_args()
request = {'command': 'webos.' + args.command, 'display': args.display}
if args.command == 'connect':
    if not args.value:
        parser.error('connect requires the TV IP address')
    request['host'] = args.value
elif args.command == 'volume':
    try:
        request['volume'] = float(args.value)
    except (ValueError, TypeError):
        parser.error('volume requires a number from 0 to 100')
elif args.command == 'brightness':
    try:
        request['brightness'] = int(args.value)
    except (ValueError, TypeError):
        parser.error('brightness requires an integer from 0 to 100')
elif args.command == 'input':
    if not args.value:
        parser.error('input requires HDMI_1, HDMI_2, HDMI_3 or HDMI_4')
    request['input'] = args.value
for name in ['mac_input', 'mac_address', 'power_sync', 'switch_on_wake']:
    value = getattr(args, name)
    if value is not None:
        key = {'mac_input': 'macInput', 'mac_address': 'macAddress', 'power_sync': 'powerSync', 'switch_on_wake': 'switchOnWake'}[name]
        request[key] = value == 'true' if name in ['power_sync', 'switch_on_wake'] else value
path = os.path.join(tempfile.gettempdir(), 'crispctl.sock')
info = os.lstat(path)
if info.st_uid != os.getuid() or not stat.S_ISSOCK(info.st_mode):
    raise SystemExit('Crisp socket unavailable or untrusted')
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(60)
    client.connect(path)
    client.sendall(json.dumps(request, allow_nan=False).encode() + b'\n')
    reply = b''
    while b'\n' not in reply:
        chunk = client.recv(4096)
        if not chunk:
            raise SystemExit('Crisp closed before responding')
        reply += chunk
        if len(reply) > 65536:
            raise SystemExit('Crisp response too large')
response = json.loads(reply.split(b'\n', 1)[0])
print(json.dumps(response, ensure_ascii=False))
raise SystemExit(0 if response.get('ok') else 1)
