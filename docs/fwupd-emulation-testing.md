# fwupd emulation testing

Verify the Firmware page install pipeline (consent dialogs, payload
resolution, `Install(fd)`, progress signals, request dialogs, reboot prompt,
error paths) against the real fwupd daemon without flashing real hardware.
fwupd's built-in `test` plugin creates a virtual `Integrated Webcam™`
(ACME Corp., GUID `b585990a-003e-5270-89d5-3705a17f9a43`, version 1.2.2)
with releases 1.2.3 / 1.2.4 from a local `fwupd-tests` remote. Installs go
through the full D-Bus, polkit and fd-passing path; no real firmware is
written.

Requires fwupd with the `test` plugin compiled in (`fwupdmgr get-plugins`)
and the shipped `/usr/share/fwupd/remotes.d/fwupd-tests.conf`. Verified
against fwupd 2.1.10.

## One-time setup

The test metadata and cabinets are not packaged on Arch; fetch them from the
matching fwupd tag and build the cabinets locally:

```sh
base=https://raw.githubusercontent.com/fwupd/fwupd/2.1.10/data/tests
mkdir -p /tmp/fwupd-test-data && cd /tmp/fwupd-test-data
for f in fwupd-tests.xml \
         fakedevice123.bin fakedevice123.jcat fakedevice123.metainfo.xml \
         fakedevice124.bin fakedevice124.jcat fakedevice124.metainfo.xml; do
    curl -fLO "$base/$f"
done
fwupdtool build-cabinet fakedevice123.cab fakedevice123.bin fakedevice123.metainfo.xml fakedevice123.jcat
fwupdtool build-cabinet fakedevice124.cab fakedevice124.bin fakedevice124.metainfo.xml fakedevice124.jcat
```

Locally built cabinets differ from the SHA1s pinned in `fwupd-tests.xml`.
Patch the `target="container"` checksums with `sha1sum` output. The
`target="content"` checksums in the upstream XML are stale too; the `.jcat`
SHA1 blobs match the actual `.bin` files and are authoritative.

Install the data (root) and enable the test devices through the daemon:

```sh
pkexec sh -c 'mkdir -p /usr/share/installed-tests/fwupd &&
    cp fwupd-tests.xml fakedevice123.cab fakedevice124.cab /usr/share/installed-tests/fwupd/'
fwupdmgr modify-config fwupd TestDevices true   # polkit prompt; answer y to restart
fwupdmgr get-releases b585990a-003e-5270-89d5-3705a17f9a43
```

Do not use `fwupdtool enable-test-devices`: it runs the engine locally as the
calling user and fails to write the daemon config. The daemon config may live
outside `/etc/fwupd` (e.g. `/var/etc/fwupd/fwupd.conf`).

## Driving the pipeline with [test] knobs

Set knobs with `fwupdmgr modify-config test KEY VALUE` (polkit
`modify-config`). They apply live and are **memory-only**: the test plugin is
`TEST_ONLY`, so values are never persisted, and a daemon restart or idle exit
wipes them. **Answer N to the restart prompt** after setting knobs. A restart
also resets the virtual device version to 1.2.2.

| Knob | Shelly path exercised |
| --- | --- |
| `RequestSupported=true`, `RequestDelay=2000` | DeviceRequest lockout dialog mid-write (daemon message wins over canned id text) |
| `NeedsReboot=true` | post-install reboot consent prompt |
| `WriteDelay=3000`, `DecompressDelay=1000`, `VerifyDelay=1000` | visible stepped progress; navigate-away mid-install |
| `WriteSupported=false` | failure dialog ("device was not in supported mode") |
| `AnotherWriteRequired=true` | second install pass (flag `1<<18`, one-shot) |

The test plugin never waits for a request response — it emits the request and
sleeps `RequestDelay`, so the install can finish while the lockout dialog is
still open. Shelly defers finish prompts until the dialog queue drains.

## polkit behavior

- Upgrades and reinstalls of trusted-payload releases on hotplug devices use
  `update-hotplug-trusted` (`allow_active=yes`): **no prompt** in an active
  session.
- Downgrades use `downgrade-hotplug-trusted` (`auth_admin_keep`): prompts
  once, then caches. To test the cancel path, downgrade and cancel the
  authentication dialog; Shelly shows the friendly denied note.
- **Reboot now really reboots the machine via logind.** Click Later while
  testing.

## Observing the wire

Unprivileged `dbus-monitor` on the system bus only sees broadcast signals
(BecomeMonitor is denied). Run it as root to capture `Install` method calls,
options and fd passing:

```sh
pkexec sh -c 'dbus-monitor --system \
    "type='"'"'method_call'"'"',destination='"'"'org.freedesktop.fwupd'"'"'" \
    "type='"'"'signal'"'"',sender='"'"'org.freedesktop.fwupd'"'"'" > /tmp/fwupd-wire.log'
```

Expect `Install(device-id, fd list, {reason: user-action, filename, ...})`
with `allow-older` / `allow-reinstall` per classification, `PercentageFull`
progress signals, and `DeviceChanged` / `Changed` on completion.

## Coverage limits

Not exercisable with the test plugin (covered by unit tests / FakeBackend):
FDE gate, branch warning and shutdown prompt (device flags are not
client-settable), post-install request drain (only IMMEDIATE requests are
emitted), UpdateMessage dialog (absent from the test metadata).

The `file://` remote resolves payloads locally (no HTTP, no cache copy).
LVFS also serves releases for the fake GUID, so picking the `lvfs` release
instead exercises the real HTTPS download, checksum verification and cache
reuse under `~/.cache/shelly/fwupd/<host>/`.

## Cleanup

```sh
fwupdmgr modify-config fwupd TestDevices false   # answer y to restart
fwupdmgr quit
```

The daemon's exit save persists the in-memory `[test]` section to the config
file; after quitting, remove that section if present. The copied data files
are inert while `TestDevices=false` and can stay for the next session.
`fwupdmgr get-devices` should no longer list the webcam.
