# PKGBUILD Parser

Shelly's **static** PKGBUILD parser. It reads a PKGBUILD and resolves its
metadata, fields, and makepkg execution plan **without ever executing the
PKGBUILD**: everything is derived by parsing and by a bash-aware expansion
engine. Anything only a real shell could evaluate (command substitution,
runtime variables) is either rejected at parse time or retained as inert,
reviewable text for the builder's post-review shell evaluation.

## Parse flow at a glance

```
PkgbuildParser.parser_content (parser.zig)
  1. build_var_hashmap          top-level assignments → variable map
                                (variables.zig; rejects command substitution)
  2. defer source-integrity control flow and arbitrary dynamic indexed arrays to reviewed sandbox evaluation
     (execution.zig)
  3. validate_selected_package / arch directives             (validation.zig)
  4. inspect_package_functions  split-package shape          (validation.zig)
  5. install/changelog file resolution                       (fields.zig)
  6. source=() + local source capture for review             (sources.zig)
  7. depends/arch arrays with ${arr[@]} and $var resolution  (fields.zig →
                                arrays.zig + dependencies.zig)
  8. parsed_depends             name/operator/version split  (dependencies.zig)
  9. execution plan             step bodies + preludes       (execution.zig)
                                → Pkgbuild struct            (types.zig)
```

`PkgbuildParser` (in `parser.zig`) is a small context value —
`{ allocator, io, selected_package_name, package_carch, dynamic_overrides,
dynamic_unsets, dynamic_array_overrides }` — passed into every module function;
split-package builds set `selected_package_name` to evaluate one
`package_<name>()` at a time. The dynamic maps contain state captured while
sourcing the reviewed PKGBUILD in the build sandbox.

## Files

| File | Role |
|---|---|
| `parser.zig` | **Orchestrator.** `PkgbuildParser` with the four entry points: `parser` (from disk), `parser_content`, `package_names`, `package_names_content`. Sequences the stages above into the `Pkgbuild` result. Also carries the 56 end-to-end fixture tests (real-world PKGBUILDs incl. split packages, scx, flutter-bin) and the `test {}` block that aggregates every module's unit tests. |
| `types.zig` | **Result types.** `Pkgbuild`, `PackageNames`, dynamic scalar/source assignment records, dependency and execution-plan types, their `deinit`s, and shared helpers. |
| `shell_scan.zig` | **Shell text primitives.** Quote-aware comment stripping, `if/fi` conditional tracking, heredoc declaration parsing, `$(…)` detection, and `split_shell_segments` — tags every slice of a snippet as expandable or literal (single-quoted/escaped) exactly like bash. Foundation of the expansion engine. |
| `function_body.zig` | **Function extraction.** `extract_function_body` pulls a named function's body out of the PKGBUILD (balanced braces, optional `function` keyword); `selected_package_body` picks `package_<name>()` with fallback to `package()`. Public entry kept on `PkgbuildParser` via alias for the install-script validators. |
| `arithmetic.zig` | **`$((…))` evaluator.** Recursive-descent arithmetic with correct precedence, parentheses, and `$var` substitution of integer variables. |
| `expansion.zig` | **The expansion engine.** Resolves bash parameter expansions against the variable map: plain `$var`/`${var}`, case conversion `${v,}`/`${v,,}`/`${v^}`/`${v^^}`, trim `${v#p}`/`${v##p}`/`${v%p}`/`${v%%p}`, replacement `${v/a/b}` (+ `//`, `/#`, `/%`), substring `${v:o:l}`, arithmetic, and command substitution (stripped for metadata, preserved for step bodies). Two modes: `.metadata` (destructive — unknowns fail later validation) and `.execution` (lossless — the shell resolves the rest at runtime). Honors quoting and heredoc semantics via `shell_scan`. |
| `arrays.zig` | **Array parsing.** `parse_array` with quoted words, escapes, per-line comments, `+=` appends, brace expansion (`pkg-{a,b}.tar` cartesian product, bounded), conditional-block skipping, and scoped `package_<name>` arrays. |
| `variables.zig` | **Variable map.** `build_var_hashmap` collects top-level `key=value` assignments (quotes, appends), avoids executing command substitution, overlays sandbox-captured scalar values and unsets, then fixpoint-resolves chained references; `inject_array_pkgname` overlays the first split-package name; `parse_variable`, `resolve_or_parse`, and the string-freeing helpers. |
| `dependencies.zig` | **Dependency handling.** `parse_dependencies` splits `name>=version` into `parsed_dep`; `resolve_variable_references` expands `$var`/`${arr[@]}` items and strips dangling constraints on unresolvable variables (with a warning). |
| `sources.zig` | **Local source handling.** Classifies resolved `source=()` entries (remote vs local, `name::url` renames), ignores deferred command-substitution entries until the sandboxed reparse, reads local files for review (32 MB cap), and labels binary content. |
| `fields.zig` | **Field resolution.** Resolves each metadata field with makepkg semantics, merges `${CARCH}`-suffixed arrays, preserves deferred source commands during analysis, and consumes sandbox-produced array overrides during the final reparse. |
| `validation.zig` | **makepkg rules.** Package-name uniqueness, reserved `xdata` keys, arch directive legality (incl. per-package overrides), package-function shape (split vs single, `build()` without `package()`), and forbidden assignments inside package bodies. |
| `execution.zig` | **Execution plan.** Extracts `verify/prepare/pkgver/build/check/package[_name]` bodies in makepkg order, reconstructs the pre-execution environment as safely quoted bash declarations and explicit unsets (`shared_prelude`/`package_prelude` with the selected split name overlaid), captures helper functions, identifies source/checksum arrays that require Bash control flow, and expands step bodies through the `.execution` mode with makepkg builtins (`pkgbase`, `startdir`, `srcdir`, `pkgdir`, `CARCH`). |

## Module dependencies

```
parser.zig ──> variables, validation, fields, sources, dependencies,
               execution, function_body, types
execution ──> function_body, expansion, arrays, variables, dependencies,
              shell_scan, types
fields    ──> function_body, variables, expansion, arrays, dependencies
validation──> types, shell_scan, function_body, fields, package_metadata
dependencies ──> shell_scan, expansion, arrays
variables ──> shell_scan, expansion, arrays
sources   ──> types, file_inspector
expansion ──> shell_scan, arithmetic
arrays    ──> shell_scan
types, shell_scan, function_body, arithmetic ──> (leaves)
```

Modules import `PkgbuildParser` from `parser.zig` for the shared context;
the resulting circular imports are intentional and legal in Zig.

## Reviewing tips

- **Start with `parser.zig`'s `parser_content`** — it reads as the stage
  index above.
- **Correctness heart:** `expansion.zig` + `shell_scan.zig` encode bash
  expansion/quoting semantics. The in-file unit tests (127 across the two)
  are the spec; heredoc bodies, single-quote runs, and backslash escapes must
  pass through untouched.
- **Security model:** no PKGBUILD code ever runs here. Source-integrity arrays
  that require command substitution or shell control flow are retained for
  atomic post-review sandboxed evaluation; other dynamic arrays remain
  rejected with `UnsupportedDynamicAssignment`. Unresolved file fields fail
  closed, newly discovered local files require supplemental review, and
  expansion/output depth and counts are bounded.
- **makepkg fidelity:** `execution.zig` prelude ordering, `${CARCH}` array
  merging in `fields.zig`, and arch/split rules in `validation.zig` mirror
  makepkg behavior — compare against makepkg sources when in doubt.
- Every module carries `//!` header docs; all but `fields`, `validation`,
  and `execution` also carry colocated unit tests (those three are exercised
  by the real-world regression fixtures in `parser.zig`'s E2E tests).

## Running the tests

```sh
cd Shelly.PackageManager
zig build test    # full suite incl. all parser module + E2E tests
zig fmt --check src/pkgbuild/parser/
```

External consumers compile against the facade
(`src/pkgbuild/pkgbuild_parser.zig`), so `zig build` + the CLI tests also
exercise the public surface.
