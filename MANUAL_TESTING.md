# Manual Testing Checklist for Shelly

This document tracks manual testing procedures for Shelly components that require human verification beyond automated
tests.

## UI Testing (Shelly-UI)

### Installation & Startup

- [ ] Application launches successfully on first run
- [ ] Application icon displays correctly in system tray/taskbar
- [ ] Window opens at appropriate size and position
- [ ] Application responds to window resize operations
- [ ] Application can be minimized/maximized/closed properly

### AppImage Environment Variables (#1719)

- [ ] Open an installed AppImage and enter `WEBKIT_DISABLE_DMABUF_RENDERER=1` in Environment Variables, then select Save Environment.
- [ ] Launch from the desktop menu and `shelly run appimage <name>`; confirm the variable reaches the application.
- [ ] Restart Shelly, sync one/all AppImages, update, and replace the AppImage with a newer filename; confirm the setting survives.
- [ ] Add/edit/remove multiple lines, including an empty value (`KEY=`); verify duplicate or invalid keys prevent saving.
- [ ] Navigate away with unsaved changes and return; confirm the draft remains. Back prompts to discard it.
- [ ] Verify a failed save keeps the draft and the previously saved launcher/settings.
- [ ] Remove the variable's line and save; confirm the normal inherited/bundled environment is restored.
- [ ] On an NVIDIA system affected by #1719, verify YARC launches successfully with the workaround.

CLI equivalents (use the exact installed name):

```sh
shelly config appimage YARC --set-env WEBKIT_DISABLE_DMABUF_RENDERER=1
shelly config appimage YARC --unset-env WEBKIT_DISABLE_DMABUF_RENDERER
shelly config appimage YARC --clear-env
```

### Package Search & Display

- [ ] Search functionality returns relevant results
- [ ] Package list displays correctly with all metadata
- [ ] Package details view shows complete information
- [ ] Package icons/images load properly
- [ ] Scrolling through large package lists is smooth
- [ ] Filtering and sorting options work as expected

### Package Installation

- [ ] Installing a package shows progress correctly
- [ ] Installation completes successfully

### Error Messages

- [ ] In a disposable package database, trigger a database lock failure. CLI, GTK, and TUI show the configured `db.lck` path and the matching, quoted removal command. The message says to remove the file only when no package manager is running.
- [ ] Trigger missing dependencies and file conflicts in a disposable environment. The explanation names the affected packages or paths and provides a next step; technical details follow it.
- [ ] Fail an AUR build step. The message includes the package name and failed stage, and build output remains available.
- [ ] Deny a GTK authorization request. The failure explains that permission was not granted.
- [ ] Verify GTK retains the specific failure in its final status and TUI displays the full explanation, including multiline lock instructions.
- [ ] Verify recoverable cleanup failures appear as warnings and cancellation does not claim that an unexpected error occurred.

### Dynamic AUR Sources

- [ ] `shelly install aur gpu-screen-recorder-ui-git` resolves its `$(sed ...)` source URL and reaches normal Git source acquisition
- [ ] The PKGBUILD review warns before a `source=()` command substitution executes
- [ ] Declining the PKGBUILD review executes no source command
- [ ] A command substitution that resolves to a local source shows a supplemental related-file review before the file is copied
- [ ] Declining the supplemental review prevents all package lifecycle functions from running
- [ ] Command substitution in non-source arrays remains a clear unsupported-PKGBUILD failure
- [ ] Success/failure notifications display appropriately
- [ ] Dependencies are shown and handled correctly
- [ ] Disk space warnings appear when needed
- [ ] Installation can be cancelled mid-process

### Package Updates

- [ ] Available updates are detected and listed
- [ ] Update all functionality works correctly
- [ ] Individual package updates work
- [ ] Update progress is displayed accurately
- [ ] Post-update notifications are shown

### Package Removal

- [ ] Package removal shows dependency warnings
- [ ] Removal process completes successfully
- [ ] Orphaned packages are identified
- [ ] Confirmation dialogs appear before removal

### AUR Integration

- [ ] AUR packages can be searched
- [ ] AUR package information displays correctly
- [ ] AUR packages can be installed
- [ ] AUR packages can be updated
- [ ] Build process output is visible
- [ ] AUR package removal works

### Flatpak Integration

- [ ] A base-only installation does not install `flatpak` or
  `shelly-flatpak-backend` as a required dependency
- [ ] `shelly --help`, `shelly --version`, and completion generation work with
  no backend installed
- [ ] A direct Flatpak command explains that `shelly-flatpak-backend` and
  Flatpak must be installed
- [ ] `list-updates all` warns, skips Flatpak, and continues other backends when
  the backend is missing
- [ ] `upgrade all` silently skips Flatpak and continues other selected
  backends when the backend is missing
- [ ] `upgrade all` still warns for an incompatible Flatpak backend and reports
  a broken Flatpak backend as a failed upgrade step
- [ ] Backup warns and exports standard/AUR records without Flatpak records
  when the backend is missing
- [ ] Installing `shelly-flatpak-backend` enables Flatpak without rebuilding
  or reinstalling the base package
- [ ] An ABI-incompatible backend is rejected with an upgrade-together message
- [ ] Flatpak packages are listed separately
- [ ] Flatpak search works correctly
- [ ] Flatpak installation succeeds
- [ ] Flatpak updates work
- [ ] Flatpak removal works
- [ ] Status and percentage events reach both terminal and `--ui-mode`
- [ ] Cancelling an in-progress Flatpak transaction stops its native
  `GCancellable` and reports cancellation once

### Repository Management

- [ ] Repository list displays correctly
- [ ] Repository synchronization works
- [ ] Repository status indicators are accurate
- [ ] Custom repositories can be added (when implemented)

### UI/UX Elements

- [ ] All buttons are clickable and responsive
- [ ] Tooltips display helpful information
- [ ] Keyboard shortcuts work as expected
- [ ] Tab navigation works properly
- [ ] Theme/styling is consistent throughout
- [ ] Text is readable and properly sized
- [ ] Icons are clear and meaningful

### Error Handling

- [ ] Network errors are handled gracefully
- [ ] Permission errors show appropriate messages
- [ ] Invalid input is rejected with clear feedback
- [ ] Application doesn't crash on unexpected errors

## CLI Testing (Shelly-CLI)

### Basic Commands

- [ ] `shelly --help` displays help information
- [ ] `shelly --version` shows correct version
- [ ] Command syntax errors show helpful messages
- [ ] Running `shelly` with no arguments still displays and confirms the combined upgrade plan
- [ ] `shelly firefox` searches standard repositories and the AUR, while recognized commands and shortcodes retain their
      normal behavior
- [ ] Bare-value results count down toward `1`, with the closest match displayed last as `1` and selected by Enter
- [ ] Entering `0` cancels SearchInstall without starting a transaction
- [ ] Selecting a standard or AUR result enters the corresponding normal install workflow

### Package Operations

- [ ] `shelly search <package>` returns results
- [ ] `shelly install <package>` installs successfully
- [ ] `shelly remove <package>` removes successfully
- [ ] `shelly update` updates all packages
- [ ] `shelly info <package>` shows package details

### Repository Operations

- [ ] `shelly sync` synchronizes repositories
- [ ] Repository refresh works correctly
- [ ] Database updates complete successfully

### AUR Commands

- [ ] AUR search works from CLI
- [ ] AUR installation works from CLI
- [ ] AUR updates work from CLI

### Custom AUR Base URL (Atoll Compatibility)

- [ ] Configure custom base URL: `shelly config set AurUrl https://atoll.seafoam-labs.org`
- [ ] Verify RPC search and package info queries against the configured base
- [ ] Verify `shelly search aur --pkgbuild <pkg>` retrieves `PKGBUILD` via Git checkout instead of cgit
- [ ] Install normal package and split package from the custom base
- [ ] Verify AUR dependency and provider resolution work against custom base
- [ ] Verify list, list-updates, update, remove, and upgrade operations work with custom base
- [ ] Verify aggregate commands (`upgrade all`, `list-updates all`) use custom base for their AUR branch
- [ ] Verify elevated operations still use the invoking user's `AurUrl` setting
- [ ] Verify `--aur-url` overrides the persistent `AurUrl` setting per command
- [ ] Switch back to official base (`shelly config set AurUrl https://aur.archlinux.org`) and verify checkout origin replacement safeguard

### Sandboxed AUR Builds (Landlock)
Requires a kernel with Landlock enabled (check `cat /sys/kernel/security/lsm`).
- [ ] `shelly build --makesrcinfo --reviewed PKGBUILD > .SRCINFO` matches
  `makepkg --printsrcinfo`, including split-package and architecture-specific
  fields
- [ ] `--makesrcinfo` writes progress/review output to stderr and only SRCINFO
  to stdout
- [ ] `--makesrcinfo` does not run `pkgver()`, `verify()`, `prepare()`,
  `build()`, `check()`, or `package()`, and does not create package artifacts
- [ ] A split PKGBUILD that conditionally appends an enabled member to
  `pkgname` builds that member when no `--package` selection is supplied
- [ ] `shelly build --package <dynamic-member> PKGBUILD` builds only that
  enabled member and rejects it when its condition evaluates false
- [ ] With `[sandbox] enabled = true` in `shellybuild.conf`, a PKGBUILD whose
  `build()` runs `ls "$HOME"` fails that listing with "Permission denied" in
  the step output while the build itself completes
- [ ] The same PKGBUILD lists `$HOME` normally with the sandbox disabled
- [ ] A step reading a file outside the allow-list (for example
  `cat "$HOME/.ssh/id_rsa"`) is denied
- [ ] Steps still have working `/tmp`, `/proc`, `/usr`, and `/etc` access
  (`nproc`, redirects to `/dev/null`, and compiler invocations succeed)
- [ ] Package signing still works with the sandbox enabled
- [ ] On a kernel without Landlock, an enabled sandbox fails the build before
  the first step instead of running unprotected
- [ ] A build that needs extra user paths succeeds after adding them to
  `[sandbox] extra_read` / `extra_write`
- [ ] A failing sandboxed step leaves a `[sandbox]` hint line in its build log

### Keyring Management

- [ ] `shelly keyring init` initializes keyring
- [ ] `shelly keyring populate` populates keys
- [ ] Keyring operations complete without errors

### Output Formatting

- [ ] CLI output is properly formatted
- [ ] Colors/markup display correctly in terminal
- [ ] Progress indicators work
- [ ] Error messages are clear and actionable
- [ ] Verbose mode provides additional details

### UI Mode Integration

- [ ] CLI can be called from UI successfully
- [ ] Output is properly captured and displayed in UI
- [ ] Error codes are correctly propagated

### Shell Completions

- [ ] `shelly utility --completions bash|fish|zsh` writes each script
- [ ] Shortcode tokens expand in a live shell (`shelly -Sa<tab>` offers
  `-Sap` and `-Sad`; `shelly -N<tab>` offers `-N` and `-Na`)
- [ ] Options complete after a shortcode (`shelly -U -<tab>` offers the
  combined-upgrade options; `shelly -B -<tab>` offers the backup options)

**Note:** isolate the generated script from completions installed by an
older package build before live-testing it. Fish lazily loads every
`shelly.fish` found on `fish_complete_path` on the first completion request,
so a stale `/usr/share/fish/vendor_completions.d/shelly.fish` mixes silently
with the script under test and produces confusing candidates. Point
`fish_complete_path` at an empty directory while testing (or reinstall the
package first); for bash and zsh use a clean shell, and regenerate
`~/.zcompdump` if zsh keeps serving stale entries.

## Installation & Deployment

### PKGBUILD Installation

- [ ] `makepkg -si` builds and installs successfully
- [ ] `shelly` and `shelly-flatpak-backend` can be packaged and installed
  independently
- [ ] `/usr/lib/shelly/libshelly-flatpak-backend.so.1` belongs only to the
  backend package
- [ ] `readelf -d /usr/bin/shelly` has no `libflatpak.so.0` or
  `libostree-1.so.1` `NEEDED` entry
- [ ] The backend has SONAME `libshelly-flatpak-backend.so.1` and a
  `libflatpak.so.0` `NEEDED` entry
- [ ] All dependencies are correctly specified
- [ ] Post-install scripts execute properly
- [ ] Files are installed to correct locations

### Web Installer

- [ ] Web install script downloads correctly
- [ ] Installation completes without errors
- [ ] All components are installed
- [ ] Desktop entries are created

### AUR Installation

- [ ] Package builds via yay/paru
- [ ] All dependencies resolve correctly
- [ ] Installation completes successfully

### Uninstallation

- [ ] Uninstall script removes all components
- [ ] Configuration files are handled appropriately
- [ ] No orphaned files remain

## System Integration

### Permissions

- [ ] Root/sudo operations work correctly
- [ ] Permission errors are handled gracefully
- [ ] User is prompted for elevation when needed
- [ ] `Shelly.Cli.Zig/scripts/test-elevation-cancellation.sh` passes without
  privileges for both SIGINT and SIGTERM
- [ ] From a normal user session with a working elevator,
  `Shelly.Cli.Zig/scripts/test-isolated-cancellation.sh` exits successfully and
  leaves neither nspawn descendants nor an isolated operation directory

### File System

- [ ] Package cache is managed correctly
- [ ] Temporary files are cleaned up
- [ ] Configuration files are preserved on update

### System State

- [ ] System package database remains consistent
- [ ] No conflicts with pacman operations
- [ ] Lock files are handled correctly

### Desktop Integration

- [ ] Desktop file launches application
- [ ] Application appears in application menu
- [ ] File associations work (if applicable)
- [ ] System notifications display correctly

## Performance Testing

### Responsiveness

- [ ] UI remains responsive during operations
- [ ] Large package lists load quickly
- [ ] Search results appear promptly
- [ ] No UI freezing during background operations

### Resource Usage

- [ ] Memory usage is reasonable
- [ ] CPU usage is acceptable during operations
- [ ] Disk I/O is efficient
- [ ] Network bandwidth usage is appropriate

## Cross-Platform Testing (Arch-based distros)

### Arch Linux

- [ ] All features work on vanilla Arch
- [ ] Integration with pacman is seamless

### Manjaro

- [ ] Compatible with Manjaro repositories
- [ ] Manjaro-specific packages work

### EndeavourOS

- [ ] Works with EndeavourOS setup
- [ ] No conflicts with EndeavourOS tools

### Other Arch-based

- [ ] Test on other Arch derivatives as available

## Regression Testing

### After Updates

- [ ] Previously working features still work
- [ ] No new crashes or errors introduced
- [ ] Performance hasn't degraded
- [ ] UI/UX remains consistent

## Notes

- Date of last full manual test: _____________
- Tester: _____________
- Version tested: _____________
- Issues found: _____________

## Known Issues

Document any known issues that are being tracked:

1.
2.
3.
