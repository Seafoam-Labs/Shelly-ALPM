# TUI keybinding configuration

The configuration service stores shortcut overrides in `Keybindings` inside
`$XDG_CONFIG_HOME/shelly/tui-settings.json` (normally
`~/.config/shelly/tui-settings.json`). Validated overrides are applied at startup.
After editing the file, use Reload in Settings to apply changes; removing overrides restores the defaults. Invalid
configuration preserves the active bindings. An interactive editor is not yet
available.

```json
{
  "Keybindings": {
    "help": "F2",
    "install": "Alt+i"
  }
}
```

Missing entries use the defaults in `commands.Bindings`. Saving omits overrides
that equal a default; restoring every default removes the `Keybindings` object.
Other TUI preferences and unrelated top-level JSON keys are preserved.

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
