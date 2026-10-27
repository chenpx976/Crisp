# LG webOS network volume (local development build)

For LG TVs whose HDMI connection does not expose DDC volume, expand the
display details and use **LG webOS TV Controls**:

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

## OLED brightness, HDMI and power (extended pairing)

Choose **Enable OLED, HDMI and Power Controls**, then approve the expanded
pairing request on the television. Existing audio pairing alone does not
grant these capabilities. Pairing credentials still stay in Keychain.

The separate **OLED pixel brightness (TV)** slider reads and writes the
picture setting `backlight`. This changes the TV's physical OLED light output;
it does not alter black level (`brightness`) or Crisp's existing software
dimming slider. The firmware must expose `settings/getSystemSettings` and
`settings/setSystemSettings`. Crisp verifies the setting by reading it back.
An unsupported/denied device request is shown separately and does not terminate
the working audio subscription.

**HDMI Quick Switch** lists only HDMI inputs reported by the TV. Each input
has a button and an optional recorded global shortcut. Recorded shortcuts use
Crisp's existing Carbon hotkey service and its recording/suspension behavior.
The existing Shortcuts action **Set Display Input** also accepts `HDMI 1`
through `HDMI 4` for a network-configured LG TV.

**Sync TV with Mac Sleep and Wake** starts disabled. Select the Mac HDMI
input and supply a TV MAC address (normally read automatically), then enable
network wake / Turn on via Wi-Fi in the TV's settings before enabling sync.
If exactly one connected HDMI input is reported and is currently active,
Crisp can preselect it; otherwise choose the Mac input manually. Always verify
this selection before enabling automation.

On system sleep Crisp checks the TV's current foreground input again. It
requests standby only when this is the selected Mac input and a valid wake
address is known. TV applications and other HDMI inputs are left alone.
System power notifications allow the bounded request to finish before sleep.
On wake, Crisp sends Wake-on-LAN packets, waits up to 30 seconds for an active
TV, reconnects, and optionally switches to the Mac input. Display-to-host power
records survive the TV disappearing from the macOS display list.

These controls use public SSAP endpoints and ordinary Wake-on-LAN; they do not
require USB debugging, root access, calibration mode or a service-menu PIN.
Firmware-dependent controls can still be unavailable. A network-wake setting
on the TV is necessary for standby recovery.

Additional local commands (TV must be extended-paired first):

```sh
python3 scripts/webos-control.py enable 2
python3 scripts/webos-control.py refresh 2
python3 scripts/webos-control.py brightness 2 40
python3 scripts/webos-control.py input 2 HDMI_2
python3 scripts/webos-control.py config 2 --mac-input HDMI_2 --mac-address 00:11:22:33:44:55
python3 scripts/webos-control.py config 2 --power-sync true --switch-on-wake true
python3 scripts/webos-control.py standby 2
python3 scripts/webos-control.py wake 2
```

`status` includes confirmed device readings, configuration and optional device
errors. No pairing keys are included. `wake` can use the remembered display
mapping even while that display is absent. Do not enable sleep sync until a
manual standby/wake round-trip succeeds.

### Separate OLED write authorization

On the tested C4, ordinary extended pairing permits reading `backlight`, but
`settings/setSystemSettings` returns `401 insufficient permissions`. The
**Authorize OLED Writes** option is therefore separate and disabled by default.
It uses LG's standard signed SSAP remote manifest, preserved unchanged for TV
verification. That signed permission bundle also includes TV app/notification
access, remote input and remote update capabilities. Crisp does not call those
extra interfaces; the UI discloses the broader bundle before opt-in. Authorize
only if comfortable granting that standard remote profile to this local build.
The corresponding CLI command is `enable-settings` and must be used only after
this separate consent. TV approval is still required.

### Hardware validation, 2026-10-27

On the LG C4, separately approved signed pairing enabled verified hardware OLED
brightness changes `90 -> 89 -> 90`. HDMI switching `HDMI_2 -> HDMI_3 -> HDMI_2`
also succeeded with foreground-input read-back. TV standby succeeded and reported
`Active Standby`, but the initial Wake-on-LAN test did not restore the screen.
Automatic power sync was therefore left disabled. The wake path now repeats
magic packets during the timeout, recognizes spaced firmware state names, and
tries the public screen-on endpoint for network-active standby.

When the TV is the Mac's only screen, do not issue a standby command and then
request more execution approvals. `python3 scripts/test-webos-power.py 2` is a
single self-contained test: it checks configuration and exercises recovery
while the display is still on, then always attempts wake in `finally`. Approve
the entire command before the screen goes off, keep the remote available, and
do not run it until the user is ready. It leaves automatic sync disabled.

Follow-up validation on 2026-10-27: after the wake retries and network-active
standby screen-on fallback were installed, the self-contained power test passed.
The TV returned to `Active` on HDMI 2, preserving OLED brightness 90 and volume 3.
The user confirmed the screen recovered automatically without using the remote.
This validates short standby recovery; deep standby and a full Mac system-sleep
cycle were not separately exercised. The user can enable sleep/wake sync after
this successful manual TV round-trip.
