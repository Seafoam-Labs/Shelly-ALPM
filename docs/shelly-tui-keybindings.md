# TUI keybinding configuration

The configuration service stores shortcut overrides in `Keybindings` inside
`$XDG_CONFIG_HOME/shelly/tui-settings.json` (normally
`~/.config/shelly/tui-settings.json`). Validated overrides are applied at startup.
External edits are detected within about one second, including atomic editor
saves. Reload in Settings also applies changes immediately. Invalid edits leave
the last working settings active and show a warning; fixing the file applies the
corrected values.

## Editing in the TUI

Open Settings, select **Keybindings**, and press Enter or Space. Use Up/Down to
select a command, then Enter or Space to capture its replacement. Escape cancels
capture. Quit, Help, and tab shortcuts are intercepted during capture; unsupported,
reserved, or conflicting keys show feedback and leave the binding unchanged.

Delete restores the selected command's default. **Restore all defaults** resets
all configurable bindings in the draft. **Save changes** (or Ctrl+S) applies and
persists edits; **Reload** discards pending changes. **Back to preferences** keeps
the draft. The list scrolls to keep the selected action visible on small terminals.
Command names and bindings stack vertically when columns would be too narrow.
Fixed navigation, confirmation, review decisions, and sudo input are not editable.

## Editing the file

```json
{
  "Keybindings": {
    "help": "F2",
    "install": "Alt+i"
  }
}
```

All editable bindings, including defaults, are written into `Keybindings` on
startup and Save. Older or partial configurations are filled automatically.
Removing an entry restores its default, which is written back into the file.
Other TUI preferences and unrelated top-level JSON keys are preserved.

External changes wait until a running package operation finishes. Unsaved TUI
Settings edits are retained: Reload uses the external file, while Save keeps
your pending edits. Unchanged files cause no redraw or CLI query.

Supported key names are printable ASCII characters, `Plus`, `F1` through `F35`,
and named keys such as `Tab`, `PageUp`, and `PageDown`. `Ctrl+`, `Alt+`, and
`Shift+` modifiers are recognized case-insensitively; command identifiers are
case-sensitive. Letters are normalized to lowercase. Shift with printable keys
is rejected because terminal encodings vary; use the resulting punctuation
symbol directly. Named/function keys can use Shift. Sequences and multiple
bindings per action are not supported.

Editable commands:

- Application: `quit`, `help`, `next_tab`, `previous_tab`.
- Packages: `install`, `remove`, `preview`, `refresh`, `refresh_list`, `filter`,
  `clear_selection`.
- Updates: `upgrade_all`, `upgrade_system`, `upgrade_aur`, `upgrade_flatpak`.
- Flatpak: `categories`, `previous_screenshot`, `next_screenshot`.
- AUR catalog: `previous_catalog_page`, `next_catalog_page`.
- Display: `toggle_wrap`, `narrow_view`, `widen_view`.

Navigation, selection, confirmation, approval/decline, and authentication input
remain fixed. Their bindings, Vim navigation aliases, Alt+1 through Alt+9, and
common input-editing controls are reserved. Global actions and shortcuts active in search fields cannot use plain printable
keys, which would intercept search and password text. Quit and its
interrupt alias resolve to the same configured key.

Validation rejects overlapping actions using the same key, while allowing
sharing between separate contexts (for example Remove/Refresh and catalog/image
paging). The overlap groups are deliberately conservative. The entire override
object is validated together, allowing two bindings to be swapped in one edit.
Unknown commands, fixed commands, malformed keys, and conflicts are errors.
Invalid existing files and failed validation are left untouched by Save.
