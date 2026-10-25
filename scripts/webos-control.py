#!/usr/bin/env python3
"""LG network-volume commands for the local Crisp development build."""
import argparse
import json
import os
import socket
import stat
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('command', choices=['connect', 'status', 'volume', 'disconnect'])
parser.add_argument('display', type=int)
parser.add_argument('value', nargs='?')
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
path = os.path.join(tempfile.gettempdir(), 'crispctl.sock')
info = os.lstat(path)
if info.st_uid != os.getuid() or not stat.S_ISSOCK(info.st_mode):
    raise SystemExit('Crisp socket unavailable or untrusted')
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(5)
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
