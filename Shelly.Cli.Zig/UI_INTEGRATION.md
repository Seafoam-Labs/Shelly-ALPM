# Shelly UI integration reference

This document is the implementation contract for a future graphical or text UI that drives the native Zig CLI. It describes only commands that are currently registered and dispatched by `Shelly.Cli.Zig`. The command catalog in [`src/cli/catalog.zig`](src/cli/catalog.zig) remains the source of truth when behavior changes; native implementations live in [`src/commands`](src/commands), and frame serialization lives in [`src/output/config.zig`](src/output/config.zig).

Use canonical long-form commands from UI code. Shortcodes are convenient for people, but are intentionally omitted here because they are compact parser aliases rather than a stable application interface.

The bare-value fallback (`shelly firefox`) is a terminal-only SearchInstall convenience: it searches standard repositories and the AUR, presents reverse-numbered choices with the closest match last as option `1`, and then enters the normal install command. UI clients must use explicit `search` and `install` commands; the fallback rejects `--ui-mode` and `--json`.

## Starting a command

Start `shelly` as a child process with an argument array, not a shell-built command string:

```text
["shelly", "--ui-mode", "list", "standard"]
```

This avoids quoting and command-injection bugs. Preserve the invoking user's `HOME`, XDG variables, locale, and Flatpak environment. AppImage metadata, AUR state, user Flatpaks, configuration, news state, and caches are user-scoped even when part of an operation later requires elevation.

Global options may be used with every command:

| Option | UI meaning |
| --- | --- |
| `--ui-mode`, `-U` | Emit framed records intended for the Shelly UI. Use this for interactive and mutating operations. |
| `--json`, `-j` | Emit one ordinary JSON document where the command supports structured output. Useful for a non-interactive query adapter. Do not combine this with `--ui-mode`. |
| `--no-confirm`, `-n` | Use deterministic safe defaults instead of waiting for UI answers. Confirmations are accepted, the first provider is selected, optional dependencies are left unselected, and unsafe PKGBUILD changes are declined. This is not an unconditional “yes to everything.” |
| `--help`, `-h` | Print command-specific terminal help. |
| `--version`, `-V` | Print the CLI version. |

For a full UI, prefer `--ui-mode` without `--no-confirm` and implement the question protocol below. For a background operation that must never prompt, add `--no-confirm` and surface any resulting error frame.

## UI transport protocol

For commands with native UI output, stdout is a line-oriented stream. Each record has this shape:

```text
[JSON]<base64-encoded UTF-8 JSON>[/JSON]\n
```

Decode each line independently. A command may emit many frames, and the decoded payload may be an event object, a question, or the command's structured result array/object. It is not valid to concatenate decoded records and parse them as one JSON document.

There are deliberate raw-output exceptions: generated documentation/completions, pacfile prompts and external diff/merge tools, the backup TOML export, and output inherited from `pacman-key`. Their command sections identify the limitation. Do not feed those raw lines to the frame decoder or expose them in a native UI until they have a dedicated structured contract.

The UI should:

1. Read stdout and stderr concurrently to avoid filling either child-process pipe.
2. Split stdout into complete lines and accept only payloads between `[JSON]` and `[/JSON]`.
3. Base64-decode and JSON-decode each payload.
4. Route payloads with `$kind` as events; route payloads without `$kind` as command results.
5. Answer questions on the child's stdin using the same framed, base64-encoded, newline-terminated format.
6. Keep stdin open until all questions are answered and the process exits.
7. Treat exit code `0` as success and any other code as failure. Also display `alpm.error` frames because they contain the actionable backend error.

### Event records

| `$kind` | Important fields | UI treatment |
| --- | --- | --- |
| `alpm.info` | `EventType`, `Message`, `Source`, `Level`, `TimeStamp` | Append a status/log entry. This kind is also used for general informational messages from coordinated operations. |
| `alpm.error` | `ErrorMessage`, `Source`, `Level`, `TimeStamp` | Display an operation error. Do not assume the process has already exited. |
| `alpm.progress` | `PackageName`, `CurrentDownload`, `TotalDownload`, `ProgressType`, `Percent`, `Message` | Update the active package/download progress. |
| `flatpak.progress` | `Status`, `Percentage` | Update Flatpak progress. |
| `appimage.progress` | `Status`, `Percentage` | Update AppImage progress. |
| `q.yesno` | `QuestionId`, `QuestionKind`, `QuestionText` | Show a confirmation and send `a.yesno`. |
| `q.pkgbuilddiff` | `QuestionId`, `PackageName`, `OldPkgbuild`, `NewPkgbuild`, `Warnings`, `DiffLines`, `SourceFiles` | Show the complete AUR review. Preserve warning severity and related files, then send `a.pkgbuilddiff`. |

A yes/no answer is:

```json
{"$kind":"a.yesno","QuestionId":"12","Accept":true}
```

A PKGBUILD review answer is:

```json
{"$kind":"a.pkgbuilddiff","QuestionId":"13","ProceedWithUpdate":true}
```

Encode that JSON as base64 and wrap it in `[JSON]...[/JSON]\n`. `QuestionId` is a string and must match the pending question exactly. Unrecognized lines and answers for another question are ignored.

## Authorization boundary

ALPM transactions and keyring changes modify system state. System-scoped Flatpak installation, repair, update, removal, remote changes, upgrade, and cleanup also require administrator authorization. User-scoped Flatpak and AppImage operations generally do not.

The terminal path can relaunch itself through `sudo` or `doas`. Several dispatchers intentionally skip their automatic relaunch while `--ui-mode` is active, so a UI must not rely on an interactive password prompt hidden behind the child process. Use one of these designs:

- launch the command through the UI's privileged broker after explicit user authorization; or
- run a narrowly scoped privileged service which starts the requested command while retaining the invoking user's identity and XDG paths.

Flatpak repair, update, and removal discover the installed scope and only require elevation for a system installation. Remote add/remove uses system scope by default; pass `--system false` explicitly for a user remote.

## Query result conventions

Commands described as returning structured data emit that data as a result frame in `--ui-mode`, or directly as JSON with `--json`. Mutation commands primarily emit event frames and use the exit code as their final outcome.

Most current result objects use PascalCase keys for compatibility with the earlier CLI; Flatpak search is the documented lower-case exception. Do not silently normalize names in the transport layer; map them into UI domain objects in one place. Important shapes are:

- Standard packages: `Name`, `Version`, `Description`, `Repository`, `Url`, `Licenses`, dependency/provision/conflict arrays, install reason/dates, `DownloadSize`, and `InstalledSize`.
- AUR packages: `Name`, `PackageBase`, `Version`, `Description`, `Url`, votes/popularity, maintainer and dates, dependency arrays, licenses/keywords, and `Explicit`.
- Installed Flatpaks: `Id`, `Name`, `Version`, `Arch`, `Branch`, `Remote`, `InstallLevel`, `InstalledSize`, `Ref`, and `FullRef`.
- AppImages: `Name`, `DesktopName`, `Version`, `Description`, `SizeOnDisk`, update-source fields, prerelease policy, command-line arguments, and `Path`. The current compatibility key is spelled `UpdateURl`; clients should accept it exactly and may also tolerate a future corrected `UpdateUrl`.
- Update rows identify the backend by their fields: standard has `CurrentVersion`/`NewVersion` and repository data; AUR has `PackageBase`; AppImage has `DownloadUrl`/`IsUpdateAvailable`; Flatpak has `Id`, `Ref`, and `InstallLevel`.
- Byte counts are raw integer bytes. Flatpak `InstallLevel` and kind/source enum values are currently numeric compatibility values; isolate their presentation mapping so it can evolve.

## Standard package commands

These commands operate on Arch repository packages, the local ALPM database, package archives, and Shelly-managed local binaries.

### `shelly search standard [package]`

Read-only search and detail command. With no source modifier, Shelly searches installed and available packages. An exact package name opens its complete detail record.

- `--available`: synchronized repository packages.
- `--installed`: local ALPM database.
- `--local`: Shelly-managed binaries under `/opt/shelly`.
- `--repos`: configured repository names; takes precedence over other search modifiers.
- `--group`: with no package, list groups; with a value, return packages in that group.
- `--detail` or `--info`: require an exact package and return one full record.
- `--show-hidden`: include packages hidden by `IgnorePkg`.
- `--limit <n>` and `--page <n>`: one-based pagination; both must be positive.

UI use: package browser, installed view, repository/group filters, and package details. A single package source returns an array; repositories/groups return string arrays; exact detail returns one object; and a combined standard/local query returns `{ "Packages": [...], "LocalPackages": [...] }`.

### `shelly install standard [packages...]`

Installs repository names, repository-qualified names, local Arch/Shelly package archives, or HTTP(S) package URLs. Multiple inputs may be submitted together.

- `--build-deps`: dependency-only workflow for build dependencies.
- `--make-deps`: include make dependencies in that workflow.
- `--no-deps`: use the ALPM nodeps transaction flag.
- `--upgrade`: synchronize and upgrade standard packages before installing.

UI use: install action and local-file/URL import. This is a privileged, interactive transaction and may ask for dependency/conflict confirmation.

### `shelly update standard [packages...]`

Updates only the named installed repository packages. Arch partial upgrades are unsafe, so Shelly emits an explicit warning and requires confirmation before the transaction. Prefer full `upgrade standard` in normal UI flows.

### `shelly upgrade standard`

Synchronizes repositories, previews available standard updates, performs a full ALPM system upgrade, and reports restart requirements. `--all` changes the request into the coordinated all-backend upgrade described below.

### `shelly downgrade [package]`

Finds older versions in package caches and archives, then installs a selected version. If the package or version is omitted in an interactive flow, selection may be required.

- `--list-options`: return candidates without installing.
- `--target <version-release-or-file>`: select an exact candidate.
- `--oldest`: choose the oldest candidate automatically.
- `--ignore`: add the package to `IgnorePkg` after success.

UI use: candidate selection screen followed by a privileged transaction. Prefer `--list-options` first, then invoke again with `--target` after the user chooses.

### `shelly list standard`

Returns installed ALPM packages.

- `--show-hidden`: include ignored packages.
- `--explicitOnly`: only explicitly installed packages.
- `--dependencyOnly`: only dependency-installed packages.

The two install-reason filters are mutually exclusive UI states.

### `shelly list-updates standard`

Refreshes update-check metadata and returns available repository updates with current/new versions, sizes, descriptions, repository metadata, and dependencies. A zero-result response is success and also emits an informational frame.

### `shelly sync [standard]`

Synchronizes configured ALPM package databases. `standard` is optional because this is the default sync backend. `--force` refreshes databases even when they appear current. This is privileged.

### `shelly remove standard [packages...]`

Removes ALPM packages or, with `--local`, Shelly-managed local binaries.

- `--cascade <bool>` defaults to true and removes dependencies that become unnecessary.
- `--no-cascade` keeps newly unnecessary dependencies.
- `--opt-deps`: remove unused optional dependencies.
- `--ripple`: also remove packages depending on the targets.
- `--remove-config`: remove package configuration files.
- `--local`: select local-binary removal.
- `--force`: force local-binary removal.

The UI should present the resolved removal plan and consequences before acceptance. ALPM removal is privileged; local removal may also require ownership repair/elevation depending on its files.

### `shelly purify standard`

Builds a cleanup plan for corrupted package archives and can add orphan and cache cleanup. It shows targets and confirms before changing state.

- `--dry-run`: return/show the plan without changes.
- `--orphans`: include orphaned installed packages.
- `--cache [keep]`: remove old cached versions, retaining three per package by default or the supplied count.

UI use: always preview with `--dry-run`, then repeat the chosen operation after confirmation. Mutation is privileged.

### Mark commands

| Command | Capability |
| --- | --- |
| `shelly mark ignore [packages...]` | List or modify `IgnorePkg`. Use one of `--list`, `--add`, `--remove`, or `--clear`. |
| `shelly mark hold [packages...]` | List or modify `HoldPkg` with the same operation flags. Clearing retains Shelly's protected entry. |
| `shelly mark explicit <package>` | Change the installed reason to explicitly installed. |
| `shelly mark dependency <package>` | Change the installed reason to dependency. |

List operations are read-only; modifications are privileged. Expose ignore and hold as separate collections because they affect upgrades and removals differently.

### `shelly news`

Fetches Arch Linux news, returns unread entries by default, and records viewed entries in the invoking user's XDG cache. `--all` includes previously viewed entries. News items are structured in UI/JSON mode and include title, publication metadata, link, and body content.

## AUR commands

AUR operations must always retain the invoking user's environment. Builds and source review occur as the user; final ALPM installation/removal can cross the privilege boundary.

### `shelly search aur <query...>`

Joins query words and searches the AUR RPC. A normal query must contain at least two characters.

- `--standard`: append high-confidence repository matches.
- `--pkgbuild`: treat each operand as an exact package name and return its PKGBUILD instead of doing a normal search. It cannot be combined with `--standard`.

### `shelly install aur [packages...]`

Fetches, reviews, builds, and installs AUR packages.

- `--build-deps`: install one package's build dependencies only.
- `--make-deps`: include make dependencies.
- `--chroot`: build with `makechrootpkg` in a clean chroot.
- `--check`: enable the PKGBUILD `check()` function.
- `--version`: require exactly `<package> <git-commit>` and install that revision.

The UI must implement `q.pkgbuilddiff`; never collapse PKGBUILD warnings into a generic yes/no dialog.

### `shelly update aur [packages...]`

Fetches, reviews, rebuilds, and reinstalls only the named AUR packages. `--check` enables PKGBUILD checks.

### `shelly upgrade aur`

Finds installed foreign packages with newer AUR or VCS revisions and upgrades them. `--check` enables PKGBUILD checks. `--singlepane` only changes terminal presentation and has no useful UI effect.

### `shelly list aur`

Returns installed AUR/foreign packages. Supports `--show-hidden`, `--explicitOnly`, and `--dependencyOnly`; the two reason filters should not be enabled together.

### `shelly list-updates aur`

Returns newer AUR and VCS revisions. `--show-hidden` includes hidden packages.

### `shelly remove aur [packages...]`

Removes installed AUR packages through ALPM. `--cascade`, `--opt-deps`, and `--ripple` control dependency removal. This is privileged and should use the same removal-consequence UI as standard packages.

## Flatpak commands

Flatpak operations may target system or user installations. When an installed target is supplied, update, repair, and removal resolve its existing scope rather than assuming one.

### `shelly search flatpak <query>`

Searches cached AppStream catalogs from all configured system and user remotes. `--limit <n>` and `--page <n>` provide one-based local pagination.

The compatibility result is `{ "hits": [...], "query": ..., "hitsPerPage": ..., "page": ..., "totalPages": ..., "totalHits": ... }`. Hit fields are also lower snake case, including `name`, `app_id`, `remote`, `download_size`, `installed_size`, and `permissions`. For each hit on the requested page, Shelly queries remote-ref information and adds sizes and permissions. When a remote cannot provide that detail, sizes are zero and permissions are empty; this is a partial-data state, not proof that the application needs no permissions.

### `shelly install flatpak <package>`

Installs an application/runtime by ID or friendly AppStream name, a `.flatpakref`, or a bundle.

- `--user`: use the user installation; system is the default.
- `--remote <name>`: select a remote explicitly.
- `--branch <name>`: branch, default `stable`.
- `--runtime`: install a runtime rather than an application.
- `--ref-file`: treat the operand as a local `.flatpakref`.
- `--bundle`: treat the operand as a local Flatpak bundle.
- `--repair`: repair an installed target as described below.

Source modifiers are validated for incompatible combinations. The UI should prefer IDs over friendly names when it already has a search result.

#### Flatpak repair

Use `shelly install flatpak <package> --repair`. Repair discovers the installed scope, uninstalls the target while leaving application configuration in place, and reinstalls it with its dependencies. Repair cannot be combined with `--user`, `--remote`, `--branch`, `--runtime`, `--ref-file`, or `--bundle`. Elevation is requested only for a system installation.

### `shelly update flatpak <package>`

Updates one installed application or runtime in its existing scope. The operand may be an ID or an unambiguous friendly name. Elevation is scope-aware.

### `shelly upgrade flatpak`

Upgrades every application and runtime with available updates in system and user installations. The UI should expect progress from multiple scopes and targets.

### `shelly list flatpak`

Returns installed applications and runtimes from system and user installations.

### Flatpak remote listing

| Command | Result |
| --- | --- |
| `shelly list flatpak remote` | Configured user and system remotes as `Name`, numeric `Scope`, and `Url`. |
| `shelly list flatpak remote <name>` | Cached AppStream applications for one named remote. |
| `shelly list flatpak remote all` | Applications from every cached remote, de-duplicated by application ID with a `Remotes` collection showing availability. |

Remote AppStream records include identity, summary/description, type, project license, developer, categories, keywords, icons, screenshots, releases, URLs, verification fields, remotes, extensions, and add-ons. An empty cache is a valid empty result; offer `sync flatpak` to refresh it.

### `shelly list-updates flatpak`

Returns available Flatpak updates with IDs, refs, current metadata, installation scope, permissions, and installed size.

### `shelly sync flatpak`

Updates cached AppStream metadata for every configured remote. This is the refresh action for Flatpak search and remote catalog screens.

### Flatpak remote mutation

```text
shelly sync flatpak remote add <name> --remote-url <url> [--system <bool>] [--gpg-verify <bool>]
shelly sync flatpak remote remove <name> [--system <bool>]
```

`--remote-url` is required for add. `--system` defaults to true and `--gpg-verify` defaults to true. Use `--system false` for a user remote. Remove rejects add-only URL/GPG options. System changes require elevation; user changes do not. Refresh AppStream metadata after a successful mutation before showing remote applications.

### `shelly remove flatpak <package>`

Removes an installed application/runtime from its discovered scope.

- `--remove-unused`: also remove dependencies made unused by the uninstall.
- `--remove-config`: remove associated application configuration after uninstall.

Configuration is preserved by default. Elevation is scope-aware.

### `shelly purify flatpak`

Plans unused dependency cleanup across system and user installations, displays the targets, asks for confirmation, and removes accepted targets. Treat the preview as a mixed-scope plan and authorize system changes appropriately.

### `shelly run flatpak [package]`

- With a package, launch the installed application.
- With `<package> --kill`, stop its running instances.
- `shelly run flatpak list` or `shelly run flatpak --list` returns running applications.

Running records contain `Application`, `Instance`, `Pid`, `ChildPid`, `Arch`, and `Branch`. `--list` and `--kill` cannot be combined. Launch/kill return status events and an exit code rather than a persistent process handle.

## AppImage commands

AppImage commands operate in the configured AppImage directory and its local metadata database.

### `shelly install appimage <location>`

Installs an existing local file with the `.AppImage` extension and updates Shelly metadata. Use a file chooser in the UI and pass the selected path as one argv element.

### `shelly list appimage`

Returns installed AppImages, paths, desktop metadata, size, launch arguments, and update-source configuration.

### `shelly sync appimage [appimage]`

With no operand, extracts/synchronizes metadata for every installed AppImage. With a case-insensitive name query, synchronizes the first matching AppImage. A missing install directory or no match is reported as information rather than a destructive error.

### Configure an AppImage update source

```text
shelly sync appimage <appimage> <url> <type> [--prerelease]
```

This three-operand overload stores the update URL/source and prerelease policy. Supported types are `None`, `StaticUrl`, `GitHub`, `GitLab`, `Codeberg`, and `Forgejo`. Use the exact enum spelling. The package must resolve to an installed AppImage. The hidden `--configure-updates` option exists only for compatibility; new UI code should use the overload shown above.

### `shelly list-updates appimage`

Checks configured update sources and returns update availability, current version, and download URL. AppImages without a usable update source may not produce an actionable update row.

### `shelly upgrade appimage`

Checks every configured source and replaces each AppImage with an available newer version. Expect download and status progress frames.

### `shelly remove appimage <appimage>`

Removes an installed AppImage. Configuration is preserved unless `--remove-config` is supplied.

### `shelly run appimage <package>`

Launches an installed AppImage resolved by name or path. `--kill` stops its tracked process. An ambiguous name or an AppImage not tracked as running is a surfaced error.

## Coordinated commands

### `shelly list-updates all`

Queries standard, AUR, AppImage, and Flatpak updates, concatenating their structured rows into one result array. `--show-hidden` affects AUR visibility. Backend failures are independent: successful rows are still returned, error frames identify failed backends, and the final exit code is nonzero if any backend failed.

### `shelly upgrade all`

Builds an invoking-user update plan, confirms it, and upgrades all selected backends. Standard and AUR planning each synchronize and read the invoking user's XDG-cached ALPM database; this also works when either backend is skipped or fails independently. The elevated transaction separately synchronizes and uses the root/system ALPM database for package resolution and downloads. The AUR portion includes VCS/development revision checks so every package selected by execution is represented in the plan. Independent backends continue after another backend fails; the overall exit is nonzero if any selected backend fails.

In terminal mode the prepared-upgrade confirmation defaults to yes (`Y/n`); pressing Enter proceeds. An explicit `n` cancels before elevation or mutation.

- `--no-repo`: skip standard packages.
- `--no-aur`: skip AUR.
- `--no-flatpak`: skip Flatpak.
- `--no-appimage`: skip AppImage.

The equivalent `shelly upgrade standard --all` is accepted, but the explicit `upgrade all` form is clearer for UI code. Keep user-scoped planning outside the privileged portion of the workflow.

## Configuration commands

Configuration values belong to the invoking user.

| Command | Capability and result |
| --- | --- |
| `shelly config` or `shelly config list` | Return the complete configuration as a key/value object. Values are display strings in the compatibility payload. |
| `shelly config get <key>` | Return `{ "<key>": "<value>" }`. Key matching follows the configuration manager's registered properties. |
| `shelly config set <key> <value>` | Parse and store one value, then emit success or error information. |
| `shelly config reset` | Restore configuration defaults. The UI should require confirmation at its own settings layer before invoking it. |
| `shelly config parallel <downloadCount>` | Set `ParallelDownloadCount`; use a positive integer control. |

For configuration mutations, inspect error frames in addition to the exit code. Read the value back after a successful set/reset so the UI reflects canonical parsing and defaults.

## Keyring commands

All keyring commands operate on the pacman keyring and require administrator authorization.

| Command | Capability |
| --- | --- |
| `shelly keyring init` | Initialize the pacman keyring. |
| `shelly keyring list` | List keys through `pacman-key --list-keys`. |
| `shelly keyring refresh` | Refresh keys from the configured keyserver. |
| `shelly keyring lsign <keys...>` | Locally sign each supplied key. |
| `shelly keyring populate [keys...]` | Populate default distribution keyrings, or the named keyrings. |
| `shelly keyring recv <keys...> [--keyserver <server>]` | Receive keys from the configured or supplied keyserver. |

Opening/completion status is framed in UI mode, but `pacman-key` currently inherits stdout and stderr, so key listings and tool diagnostics remain terminal-oriented raw output. If the future UI needs a browsable key model, add a dedicated structured result contract instead of scraping `pacman-key` text.

## Backup and utility commands

### `shelly backup --export`

Builds and writes a type-grouped TOML backup of explicitly installed standard packages, AUR packages, and Flatpak applications. `--export` is required; invoking `backup` without it is a validation error.

- `--export`: write the current state to a file.
- `--name <name>`: file name without `.toml`.
- `--output <directory>`: destination directory.

Use this as an export action and surface the final file path. Do not infer that it backs up package contents or application configuration; it records package selections. The current command writes raw TOML and a status line even in UI mode, so run it as a controlled raw-output export or add a framed result before integrating it into a native screen.

### `shelly utility`

Exactly one primary utility mode should be selected:

- `--fix-permissions`: restore the invoking user's ownership of Shelly configuration, cache, and data directories. This requires elevation.
- `--repair-db`: remove a stale database lock (`/var/lib/pacman/db.lck`) if present. This requires elevation.
- `--docs`: write generated Markdown CLI reference as raw stdout. Capture it as text or redirect it to a user-selected file outside the CLI.
- `--completions bash|fish|zsh`: write a completion script as raw stdout.
- `--pacfiles`: run pacdiff-compatible `.pacnew`, `.pacorig`, and `.pacsave` management.

Pacfile discovery and behavior options:

| Option | Capability |
| --- | --- |
| `--pacmandb` | Discover backup paths through the local pacman database; this is the default. |
| `--find` | Recursively scan configured/default search paths. Repeat `--search-path <path>` to supply roots. |
| `--locate` | Use the system `locate` database. |
| `--output` | Print discovered pacfile paths without modifying them; best mode for a UI discovery pass. |
| `--backup` | Save the old original as `.bak` before overwriting. |
| `--threeway` | Use an older cached package as a three-way base. Repeat `--cachedir <path>` to add caches. |
| `--diff-program <command>` | Override `DIFFPROG`. |
| `--merge-program <command>` | Override `MERGEPROG`. |
| `--sudo` | Explicitly request elevation; interactive maintenance already elevates when required. |
| `--nocolor` | Disable colored status text. |

Interactive pacfile management offers pacdiff-style review actions such as view, merge, replace, delete, skip, and abort. It mutates files commonly owned by root. A future UI should first invoke `--pacfiles --output` to obtain candidates, then either provide a dedicated structured pacfile API or run the interactive workflow in a terminal component. Do not scrape prompts as a long-term UI contract.

## Suggested screen-to-command mapping

| UI surface | Query command | Mutation command |
| --- | --- | --- |
| Standard packages | `search/list/list-updates standard` | `install/update/upgrade/remove/downgrade standard` |
| AUR browser | `search/list/list-updates aur` | `install/update/upgrade/remove aur` |
| Flatpak store | `search flatpak`, `list flatpak remote ...` | `install/update/remove/repair flatpak` |
| Flatpak remotes | `list flatpak remote` | `sync flatpak remote add/remove`, then `sync flatpak` |
| Running applications | `run flatpak list` | `run flatpak <id>` or `run flatpak <id> --kill` |
| AppImages | `list/list-updates appimage` | `install/sync/upgrade/remove/run appimage` |
| Updates dashboard | `list-updates all` | `upgrade all` with backend skip flags |
| System cleanup | dry-run/list queries | `purify standard`, `purify flatpak`, removal commands |
| Package policy | `mark ignore/hold --list` | mark add/remove/clear and reason changes |
| Settings | `config [list]` / `config get` | `config set/reset/parallel` |
| Settings (maintenance) | — | `utility --fix-permissions`, `utility --repair-db` |

## UI implementation checklist

- Use argv arrays and canonical long-form commands.
- Use `--ui-mode` for operations and decode every frame independently.
- Implement both question answer types before enabling interactive AUR or ALPM mutations.
- Preserve the invoking user's environment across the authorization boundary.
- Distinguish user and system Flatpak scopes in every confirmation.
- Treat empty arrays as successful empty states.
- Retain partial results when `list-updates all` reports one failed backend.
- Keep raw byte counts and enum values in the data layer; format them in the UI.
- Display backend error frames and the final exit status.
- Never parse colored tables, help output, or pacfile prompts as durable structured data.
- Add contract tests using recorded decoded frames before changing event fields or compatibility JSON keys.
