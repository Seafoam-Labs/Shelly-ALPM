# Testing `shelly-key`

## `shelly-key --init`

Always test against a throwaway path. Never an existing in-use keyring.
(regenerating master key breaks signature verification).

### Build & run

```bash
zig build
./zig-out/bin/shelly-key --init /tmp/test-gnupg
```

`--init` requires root; the tool self-elevates if not root.

### Verify

#### Permissions

```bash
ls -ld /tmp/test-gnupg # 0755
ls -l /tmp/test-gnupg/
```

| Path             | Mode   |
| ---------------- | ------ |
| `gnupg/`         | `0755` |
| `trustdb.gpg`    | `0644` |
| `gpg.conf`       | `0644` |
| `gpg-agent.conf` | `0644` |

#### Config files

```bash
cat /tmp/test-gnupg/gpg.conf
# no-greeting
# no-permission-warning
# keyserver-options timeout=10
# keyserver-options import-clean
# keyserver-options no-self-sigs-only

cat /tmp/test-gnupg/gpg-agent.conf
# disable-scdaemon
```

#### Master key

A fresh run must print both:

```text
Generating master key. This may take some time.
Updating trust database...
```

Then confirm the key exists:

```bash
sudo gpg --homedir /tmp/test-gnupg -K
# -> Pacman Keyring Master Key <pacman@localhost>

sudo gpg --homedir /tmp/test-gnupg --list-secret-keys --with-colons
# -> a "sec:u:4096:..." line
```

#### Idempotency

Re-run the same command. Since a secret key now exists:

- Neither progress message prints.
- No second key is generated (`gpg -K` still shows one).
- `gpg.conf` options are not duplicated.

This confirms `checkTrustdb` runs **only** after key generation, not on every `--init`.

### Revert

Everything `--init` creates lives inside the keyring directory:

```bash
gpgconf --homedir /tmp/test-gnupg --kill gpg-agent
sudo rm -rf /tmp/test-gnupg
```
