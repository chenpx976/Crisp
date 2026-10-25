# LG webOS network volume (local development build)

For LG TVs whose HDMI connection does not expose DDC volume, expand the
display details and use **LG webOS TV Volume**:

1. Put the Mac and TV on the same local network. Enter the TV's private IPv4
   address, from its network settings, and click **Connect**.
2. Approve the pairing request on the TV. The volume slider appears after
   the first successful audio status response.
3. Select the TV as the macOS audio output. Click **Enable Volume Keys** and
   grant Accessibility access to this development build if needed.

On macOS 15 and later, also allow **Crisp LG** under System Settings >
Privacy & Security > Local Network. A blocked local-network request can
misleadingly appear as "The Internet connection appears to be offline".
The controller retries automatically after access is granted.

The slider and media keys change the TV's actual speaker volume. Changes
made with the TV remote are reflected in Crisp. Mute uses the existing
zero/restore behavior. Positive volume also unmutes a TV muted by its remote.
The app remembers the display-to-IP mapping, stores the pairing key in macOS
Keychain, subscribes to audio status, and reconnects every five seconds when
the TV becomes unreachable or an audio command/subscription fails. Only
registration rejection stops automatic retries; use **Pair Again** to
discard the stored key and request fresh approval.
**Disconnect** removes the display mapping and restores DDC probing; it keeps
the key for a future connection. The TV's authorized-device list can revoke it.

This implementation uses encrypted webOS SSAP on port 3001, restricted to
private IPv4 addresses and LG's known TV/issuer certificate fingerprints.
It does not accept arbitrary self-signed certificates or fall back to plain
WebSockets. A firmware change to the LG certificate may require updating the
pins. It supports legacy and nested `volumeStatus` response formats.

Protocol reference: <https://github.com/hobbyquaker/lgtv2> (registration,
audio/getVolume, audio/setVolume, audio/setMute and LG TLS fingerprints).
No third-party runtime or library is added.

This is a local modification, not an upstream release. Do not install an
upstream update over it if you want to retain the network controller.
Hardware validation on 2026-10-25: Mac mini M2 Pro, macOS 26.1, LG C4
(`LG TV SSCR2`). Encrypted pairing and volume subscription succeeded. A
12 -> 11 -> 12 volume change was confirmed from separate TV subscription
read-backs, and the original level was restored. After granting Accessibility
access and restarting the development build, the user confirmed that keyboard
volume control works.

## Local command-line control

With this build running, `python3 scripts/webos-control.py` uses the existing
same-user Crisp socket. Substitute the display ID from `crispctl display list`:

```sh
python3 scripts/webos-control.py connect 2 192.168.1.20
python3 scripts/webos-control.py status 2
python3 scripts/webos-control.py volume 2 15
python3 scripts/webos-control.py disconnect 2
```

`connect` starts pairing asynchronously. Wait for `status` to report `ready:
true` before changing volume. The `volume` response acknowledges queueing,
not TV read-back; query status afterwards to check the subscribed state.
The status exposes network error details without printing the pairing key.

## Confirmation and Keychain behavior

Slider and keyboard targets stay visible while waiting for TV read-back.
Older volume notifications cannot overwrite a newer target. After two seconds
without a matching notification, Crisp returns to the last confirmed TV
volume and reports the timeout. New input restarts the deadline.

Keychain operations use a background serial queue, including reads and
deletion. Read/delete errors stop the attempted pairing operation and show
an actionable warning. A failed save leaves the current TV connection usable,
keeps its key in memory for reconnection, and displays a persistent warning
that pairing may be needed after restart. The menu and CLI `warning` field
expose this separately from normal connection status.

Run `scripts/test-webos.sh` with full Xcode selected, or `make test` for the
entire repository suite. The focused tests run the actual controller against
in-memory sockets and a fake Keychain API. They cover delayed confirmations,
timeouts, retryable errors, rejected pairing, cancellation, and Keychain
read/update/add/delete outcomes without accessing real TV credentials.
