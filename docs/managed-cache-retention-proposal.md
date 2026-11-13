# Managed package cache retention proposal

**Status: proposal for discussion; interim patches carried by the Devario build.** 11 November 2026.

Facts below were verified against the `v3.2.0` tag sources.

## Current situation / problem

Devario OS builds Shelly from tag `v3.2.0` with the native RLPM backend
(`-Dlibalpm=false`) and is adding a package backup/restore feature: a dedicated
partition that keeps exactly three version-pinned restore points, each
combining `shelly backup --export` output with a signed archive snapshot
(`.pkg.tar.*` + `.sig`, published with `shelly repo-db add`).

For a snapshot to be trustworthy, the package cache must retain installed and
upgraded archives deterministically. Retention would be owned by Devario's
backup tooling rather than by an interactive prompt: the cache would be
**managed**.

`DisableCacheClean` exists in `Shelly.Cli.Zig/src/config/defaults.zig`, but in
`Shelly.Cli.Zig/src/commands/upgrade.zig` it only takes effect for aggregate
upgrades:

```zig
fn disableCacheClean(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) bool {
    if (!upgradesAll(invocation)) return false;
    ...
}
```

Meanwhile `runStandard()` calls `runCacheClean(...)` unconditionally after a
successful upgrade. Consequences for a distribution that wants managed cache
retention:

1. Standalone `shelly upgrade standard` — the most common upgrade command —
   still reaches the cache-clean path regardless of the setting. The
   `cache_clean_extra_entries` confirmation uses `default_response = .accepted`,
   and in automated contexts (for example stdin at EOF) the accepted default
   appears to be taken, so cleanup
   (`plan_cache_cleanup(.{ .keep = 3 })`) can silently delete cached archives a
   downstream retention tool still needs.
2. `AutoConfirmCacheClean` is also aggregate-only, so the prompt cannot even be
   pre-empted for `upgrade standard`.
3. Elevation carry-over (`upgradeArgumentsWithCacheCleanPolicy`) only propagates
   the cache policy for aggregate upgrades, because both policy helpers share
   the `upgradesAll` gate.
4. There is no distribution-level default. User configuration lives in
   `~/.config/shelly/config.json`, and automated runs (such as Devario's
   in-target installer transaction) use isolated XDG directories, so the
   compile-time default in `defaults.zig` is the only thing that governs them —
   and it is `false`.

A related question: the intended `OperationContext.ask` semantics under
`--no-confirm` ("safe automatic answers") should arguably not default to
accepting a deletion. Please confirm whether the accepted default in
`runCacheClean` is intentional.

## Proposed solution

1. **Honor `DisableCacheClean` (and `--disable-cache-clean`) for every upgrade
   path, not just aggregate ones.** This reads like an oversight rather than an
   intentional exclusion; it also fixes elevation carry-over automatically via
   `upgradeArgumentsWithCacheCleanPolicy`.
2. **Let distributions default it to `true` without forking behavior** — either
   a build option (for example `-Ddefault-disable-cache-clean=true`, alongside
   the existing path-profile options) or a system-level configuration file that
   user configuration can still override. Either would let a distribution
   declare "cache retention is managed by system tooling" out of the box.
3. **Apply the same policy to the GTK UI's "Clean Package Cache" action**
   (`Shelly.Ui.Gtk`): in managed mode it should hide the action or route it
   through the same setting; today it clears caches regardless of retention.
4. `shelly purify standard --cache/--aur-cache` remaining explicit,
   user-initiated overrides is acceptable — no change requested.

## Test impact for (1)

Three `check()` expectations encode the current aggregate-only semantics and
would need updating:

- `upgrade.zig`: "disabled cache cleaning is limited to aggregate upgrades and
  survives elevation"
- `upgrade.zig`: "default cache clean policy does not alter elevated arguments"
- `defaults.zig`: the `expect(!…DisableCacheClean)` default assertion

## Interim position

Until upstream decides, the Devario build carries local patches that remove the
`upgradesAll` gate, default `DisableCacheClean` to `true`, and update the tests
above. The goal is to drop those patches; happy to send the changes as a PR in
whatever shape is preferred (plain bugfix for (1), plus a build or system-config
option for (2)).

## Related: `SigLevel` inheritance for `file://` repositories

The restore flow installs from a `file://` snapshot repository with
`SigLevel = PackageRequired` against embedded signatures. The RLPM inheritance
quirk for local repository sections (an unset `SigLevel` behaves as if
inherited; Devario works around it in `iso/shelly.build.conf`) matters here. Is
that inheritance behavior planned, or should it be a separate issue?
