# PKGBUILD Parser

Shelly's **static** PKGBUILD parser. It reads a PKGBUILD and resolves its
metadata, fields, and makepkg execution plan **without ever executing the
PKGBUILD**: everything is derived by parsing and by a bash-aware expansion
engine. Anything only a real shell could evaluate (command substitution,
runtime variables) is either rejected at parse time or left literally in the
step bodies for the builder's shell to handle.

## Parse flow at a glance

```
PkgbuildParser.parser_content (parser.zig)
  1. build_var_hashmap          top-level assignments → variable map
                                (variables.zig; rejects command substitution)
  2. validate_execution_assignments   no dynamic arrays      (execution.zig)
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
`{ allocator, io, selected_package_name, package_carch }` — passed into every
module function; split-package builds set `selected_package_name` to evaluate
one `package_<name>()` at a time.

## Files

| File | Role |
|---|---|
| `parser.zig` | **Orchestrator.** `PkgbuildParser` with the four entry points: `parser` (from disk), `parser_content`, `package_names`, `package_names_content`. Sequences the stages above into the `Pkgbuild` result. Also carries the 56 end-to-end fixture tests (real-world PKGBUILDs incl. split packages, scx, flutter-bin) and the `test {}` block that aggregates every module's unit tests. |
| `types.zig` | **Result types.** `Pkgbuild`, `PackageNames`, `parsed_dep`, `split_entry`, `kvp`, `execution_step`, `execution_plan`, their `deinit`s, `get_full_version`, and the shared `contains_string` helper. |
| `shell_scan.zig` | **Shell text primitives.** Quote-aware comment stripping, `if/fi` conditional tracking, heredoc declaration parsing, `$(…)` detection, and `split_shell_segments` — tags every slice of a snippet as expandable or literal (single-quoted/escaped) exactly like bash. Foundation of the expansion engine. |
| `function_body.zig` | **Function extraction.** `extract_function_body` pulls a named function's body out of the PKGBUILD (balanced braces, optional `function` keyword); `selected_package_body` picks `package_<name>()` with fallback to `package()`. Public entry kept on `PkgbuildParser` via alias for the install-script validators. |
| `arithmetic.zig` | **`$((…))` evaluator.** Recursive-descent arithmetic with correct precedence, parentheses, and `$var` substitution of integer variables. |
| `expansion.zig` | **The expansion engine.** Resolves bash parameter expansions against the variable map: plain `$var`/`${var}`, trim `${v#p}`/`${v##p}`/`${v%p}`/`${v%%p}`, replacement `${v/a/b}` (+ `//`, `/#`, `/%`), substring `${v:o:l}`, arithmetic, and command substitution (stripped for metadata, preserved for step bodies). Two modes: `.metadata` (destructive — unknowns fail later validation) and `.execution` (lossless — the shell resolves the rest at runtime). Honors quoting and heredoc semantics via `shell_scan`. |
| `arrays.zig` | **Array parsing.** `parse_array` with quoted words, escapes, per-line comments, `+=` appends, brace expansion (`pkg-{a,b}.tar` cartesian product, bounded), conditional-block skipping, and scoped `package_<name>` arrays. |
| `variables.zig` | **Variable map.** `build_var_hashmap` collects top-level `key=value` assignments (quotes, appends), rejects command substitution, then fixpoint-resolves chained references; `inject_array_pkgname` overlays the first split-package name; `parse_variable`, `resolve_or_parse`, and the string-freeing helpers. |
| `dependencies.zig` | **Dependency handling.** `parse_dependencies` splits `name>=version` into `parsed_dep`; `resolve_variable_references` expands `$var`/`${arr[@]}` items and strips dangling constraints on unresolvable variables (with a warning). |
| `sources.zig` | **Local source handling.** Classifies `source=()` entries (remote vs local, `name::url` renames), reads local files for review (32 MB cap), and marks ELF/binary content with a review notice instead of raw bytes. |
| `fields.zig` | **Field resolution.** Resolves each metadata field with makepkg semantics: `${CARCH}`-suffixed arrays (`source_x86_64`, `sha256sums_x86_64`, …), package-scoped overrides inside `package_<name>()`, install/changelog file resolution, effective `arch`. |
| `validation.zig` | **makepkg rules.** Package-name uniqueness, reserved `xdata` keys, arch directive legality (incl. per-package overrides), package-function shape (split vs single, `build()` without `package()`), and forbidden assignments inside package bodies. |
| `execution.zig` | **Execution plan.** Extracts `verify/prepare/pkgver/build/check/package[_name]` bodies in makepkg order, reconstructs the pre-execution environment as safely quoted bash declarations (`shared_prelude`/`package_prelude` with the selected split name overlaid), captures helper functions, and expands step bodies through the `.execution` mode with makepkg builtins (`pkgbase`, `startdir`, `srcdir`, `pkgdir`, `CARCH`). |

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
- **Security model:** no PKGBUILD code ever runs here. Command substitution
  is rejected for metadata (`UnsupportedDynamicAssignment`), unresolved
  `$vars` in file fields fail with `UnresolvedPkgbuildVariable`, local file
  contents are captured for human review with binaries labeled, and expansion
  depth/counts are bounded (brace expansion, array recursion).
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
