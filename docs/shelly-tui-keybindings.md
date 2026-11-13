# TUI keybindings

Customize shortcuts in **Settings → Configure keybindings**, or edit
`~/.config/shelly/tui-settings.json`. 

If `XDG_CONFIG_HOME` is set, the file is
stored under `$XDG_CONFIG_HOME/shelly/` instead.

## Using Settings

Wide terminals show settings on the left and details or an editor on the right.
Selecting Icons or Configure keybindings previews the available choices.
Narrow terminals use a single pane.

- **Right / `l`**, **Enter**, or **Space**: focus the selected editor.
- **Left / `h`**: return to settings, keeping pending edits.
- **Up / Down**: select a setting or command.
- **Ctrl+Left / Ctrl+Right**: resize the panels.
- **F1**: open help in the right pane, or full-page on narrow terminals.

Resize and help shortcuts above are defaults and follow your custom bindings.

Lists scroll to keep the selection visible. On narrow terminals, command names
and their bindings appear on separate lines.

## Changing a binding

1. Select a command and press **Enter** or **Space**.
2. Press the replacement shortcut. **Escape** cancels recording.
3. Choose **Save changes** or press **Ctrl+S** to apply your edits.

While recording, Quit, Help, and tab shortcuts are captured as input. Unsupported,
reserved, or conflicting shortcuts show an error and leave the binding unchanged.

- **Delete** restores the selected command's default in the draft.
- **Discard changes** restores the active settings.
- **Reload** reads settings from the file and discards pending edits.
- Save and Discard sit below Keyboard in the left pane; use **Up / Down** to reach them.
- Pressing **Down** on the last binding moves to Save changes.

Navigation, selection, confirmation, approval/decline, and authentication keys
cannot be customized.

## Editing the file

Bindings are stored in the `Keybindings` object. For example:

```json
{
  "Keybindings": {
    "help": "F2",
    "install": "Alt+i"
  }
}
```

- Settings load at startup. File edits are usually detected within one second.
- All editable bindings, including defaults, are written at startup and when saved.
- Missing entries are filled with defaults. Remove an entry to reset it.
- Other preferences and unrelated JSON fields are preserved.
- Invalid edits show a warning and keep the last working settings active. Fixing
  the file allows the corrected settings to load.

External edits wait while a package operation is running or settings have unsaved
changes. 

- **Reload** uses the file.
- **Save** keeps your pending edits. 
 
Save leaves an invalid existing file untouched, so correct the file first.

## Supported shortcuts

Use one key, optionally combined with `Ctrl`, `Alt`, or `Shift`:

- Printable ASCII characters, such as `i`, `/`, or `[`.
- `Plus` for the `+` key.
- Function keys from `F1` to `F35`.
- Named keys, such as `Space`, `PageUp`, or `PageDown`, subject to reserved-key rules.
- Combinations such as `Alt+i`, `Ctrl+PageDown`, or `Ctrl+Shift+F2`.

Key names and modifiers are case-insensitive. Command identifiers are
case-sensitive. Letters are normalized to lowercase.

`Shift` is supported with named and function keys, but not printable characters.
For punctuation, enter the resulting symbol directly. Key sequences and multiple
shortcuts per command are not supported.

## Available commands

These groups match the Settings editor:

- **General:** `quit`, `help`, `next_tab`, `previous_tab`, `refresh`,
  `narrow_view`, `widen_view`.
- **Packages:** `install`, `remove`, `refresh_list`, `filter`, `clear_selection`.
- **Updates:** `upgrade_all`, `upgrade_system`, `upgrade_aur`, `upgrade_flatpak`.
- **AUR catalog:** `previous_catalog_page`, `next_catalog_page`.
- **Flatpak details:** `categories`, `previous_screenshot`, `next_screenshot`.
- **PKGBUILD:** `preview`, `toggle_wrap`.
- **File picker:** `toggle_hidden` (default: `.`). Hidden files and folders are
  excluded until toggled; this shortcut applies while browsing, not editing a path.

## Conflicts and reserved keys

- Fixed navigation keys, Vim aliases, Alt+1 through Alt+9, and common text-editing
  controls are reserved.
- Global shortcuts and actions available while searching require Ctrl, Alt, or a
  function key, so they do not consume ordinary text.
- Commands active in the same context cannot share a shortcut. Separate contexts
  can share keys, such as AUR paging and Flatpak screenshots.
- Quit and its interrupt alias use the same configured shortcut.
- The complete configuration is validated together, so you can swap two bindings
  in one file edit.

Unknown commands, attempts to rebind fixed commands, malformed shortcuts, and
conflicts are rejected.
