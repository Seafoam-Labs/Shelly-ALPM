# Resolution plans

RLPM implements native install, removal and system-upgrade selection through
`Owner.resolve(io, request)`. It returns an owned `TransactionPlan`. The
resolver follows the pinned CachyOS libalpm dependency walk and repository
priorities. The transaction API adds transaction states, locks and the
prepare/commit contract; see [transactions](transactions.md). Nonempty commit
also requires downloads, filesystem preflight, actions and payload execution.

```zig
var plan = try owner.resolve(io, .{
    .install = &.{.{ .text = "cachyos/linux-cachyos" }},
    .system_upgrade = true,
    .flags = .{ .needed = true },
});
defer plan.deinit();
try plan.check();
// Present plan.additions, plan.removals, plan.questions and plan.warnings.
// plan.package(addition.package) returns owned metadata for each addition.
```

`Request.install` accepts text relations (optionally repository-qualified), a
current `PackageRef`, or a borrowed archive `*const Package`. Direct package
inputs follow `alpm_add_pkg`; text lookup performs provider/ignore questions.
`remove` contains local package names. `system_upgrade` adds upgrades and
consented replacements; `allow_downgrade` enables system downgrades. Explicitly
requested older versions already permit downgrades. Groups can be expanded with
the existing Owner group queries before constructing the request.

Call `plan.check()` before treating the package set as successful. Semantic
failures return a plan with `failure` and owned `issues`: missing relations with
requiring/causing packages, conflict pairs/reasons, invalid architectures,
duplicate candidates/filenames or unresolved target text. Failed-plan package
lists are provisional. Operational errors, including allocation failure,
cancellation, invalid answers, stale references and unavailable metadata, throw
and set `Owner.diagnostic()`. A semantic failure is held by its plan rather than
overwriting another plan's diagnostics.

## Selection and ordering

Local and repository snapshots have ordered name, provision and reverse
dependency indexes. All requested packages share a dependency graph. Literal
matches across eligible repositories precede provider choices. Repository order
wins over newer versions in later repositories. An installed provider name is
preferred among sync providers; otherwise multiple providers ask the frontend.
Provider candidates retain repository identity even when names repeat.

Runtime dependencies alone expand the graph. Installed satisfiers, explicit
targets, selected packages and assumed provisions participate according to the
reference's ordering rules. Separate constraints can be satisfied by different
providers, including the reference's known dependency-range limitation. Missing
top-level targets are offered through `remove_packages`. Acceptance recomputes
the retained targets and reuses answers to unchanged provider questions. Changed
candidate lists require a new answer. Dependency walks and sorting use explicit
stacks; binary dependency cycles produce ordered plans and warnings.

The final check uses installed packages minus removals, replacements and old
upgrade versions, plus additions. It checks surviving installed packages when
a changed package formerly satisfied their dependency. Unrelated pre-existing
broken dependencies do not fail a transaction. Conflict checks run in both
directions, use versioned provisions and retain the first conflict reason. A
conflicting target that provides the other target's name can replace that target
automatically. Removing an installed conflict requires a question answer.

Removal handles cascade, recursive dependency cleanup, explicit-dependency
inclusion and unneeded filtering. Shared providers and cycles follow the native
selection rules. Optional dependencies generate warnings and do not prevent
recursive removal. System upgrades examine local names and repository priority,
try replacements before literal upgrades, preserve packages absent from sync
repositories, honor ignored packages, and transfer replacement reasons.

The reference checks architecture on initial targets before pulling
dependencies; RLPM preserves that distinction. Exact configured CachyOS
architectures such as `x86_64_v3` are accepted. Install candidate lookup accepts
repository usage `install OR upgrade`; automatic system upgrades require
`upgrade`.

## Flags, queries and option handling

`TransactionFlags.fromBits`/`toBits` preserve the 16 pinned flag values and reject
unknown/reserved bits. Solve-time behavior covers `no_dependencies`,
`no_dependency_versions`, `no_conflicts`, `needed`, `cascade`, `recurse`,
`recurse_all`, `unneeded`, `all_dependencies` and `all_explicit`, including
combinations. `recurse_all` alone does not enable recursion. `no_dependencies`
skips closure/checks/sorting while retaining conflict checks. Conflicts and
ordering still use full versions under `no_dependency_versions`.

`no_save`, `database_only`, `no_hooks`, `download_only`, `no_scriptlets` and
`no_lock` are retained for the corresponding execution stages. Plans calculate
both the preparation reason and the final installation reason; old reasons
survive upgrades, and `all_dependencies` takes precedence over `all_explicit`.

IgnorePkg/IgnoreGroup use libc `fnmatch` with no negation convention. Ignored
explicit text targets can prompt, ignored dependency candidates are skipped,
and ignored system upgrades produce warnings. `Owner.shouldIgnore` exposes the
same matching. `Owner.newVersion(io, package)` reports a newer version from the
first literal repository match; this query intentionally ignores usage and ignore
policy, as the pinned helper does. Use a system-upgrade plan for policy decisions.

AssumeInstalled entries are provisions: only unversioned and exact-version
relations are accepted. Raw version strings and descriptions stay permissive;
general package dependencies still support every comparator. Configure the full
list with `setOptions`, append with `addAssumedInstalled`, or remove the first
matching name/raw-version using `removeAssumedInstalled`. Removal ignores the
comparator/description and does not normalize equivalent-looking version strings.

The standalone `Resolver.resolve` accepts a borrowed `Snapshot`, `Options`,
`Request` and optional question/cancellation `Context`. It performs no I/O.
Snapshot entries must come from complete metadata with unique database package
identities; repository order is significant, package input order is normalized
by name. `findSatisfier`, `newVersion` and `shouldIgnore` expose the
corresponding query primitives. The Owner adapter loads databases under the
existing verification policy, strictly loads local descriptions and validates
references. Removal does not require sync files. Missing repositories are
tolerated for archive-only preparation; sync targets require all registered
databases present.

## Ownership and review data

A plan owns its candidate metadata, actions, dependency edges, selected
provisions, unchanged satisfiers, answers, warnings and diagnostics. It remains
readable after cache invalidation or Owner release. Edges describe the final
future state, including surviving local packages, retain original constraints,
and identify an assumed provision or a concrete package/provision. Addition and
removal slices are already in operation order.

Treat plan fields as immutable. Call `deinit` exactly once and do not
shallow-copy an initialized plan. Each verified archive keeps a separate
descriptor for the same sealed bytes checked during verification; freeing the
caller's package or overwriting its original pathname cannot change those bytes.
Metadata-only archive inputs retain their metadata-only validation status and do
not acquire an integrity claim.

Resolution question payloads include borrowed `PackageView` metadata because
callbacks cannot reenter Owner. They can change only the answer field. Answers
with an invalid union tag/provider index fail without publishing a plan.
Archive references use the reserved `DatabaseRef.Id.archive` and a unique plan
generation. Resolve them through `plan.findReference`, never `Owner.package`.
Callbacks and long resolution walks honor cancellation; callers can reset the
Owner's cancellation flag and retry.

`sizes` contains known installed additions/removals, unknown counts and a
compressed download upper bound. Download planning must account for cache hits,
partial files and actual transfers. Each addition also retains its selected
repository as `installed_database`, while old CachyOS provenance remains in
local metadata. Writing that provenance belongs to the executor. Plans take no
transaction lock and are not executable authorizations. Transaction preparation
binds a transaction-owned plan to frozen options and a live database snapshot;
changed state requires a new transaction/review.

## Evidence and remaining boundaries

`zig build test-resolver` runs 12 public-consumer tests, also included in `test`.
The offline [reference fixture](src/tests/fixtures/resolver-reference.json)
contains 314 prepare scenarios: 36 adaptations from the frozen pacman corpus,
118 focused cases and 160 generated universes (seed 540941). Nine independent
option cases check AssumeInstalled comparator validation. Results compare
ordered package identities, preparation reasons, removals, questions/answers,
cycle warnings, failure categories and dependency/conflict payloads. Native
query results also check final dependency edges/provisions, ignore decisions
and new-version lookup. Filesystem assertions in the original pacman scripts
are outside these prepare-only adaptations; known upstream expected-failure
cases preserve the pinned library's observed results.

Additional tests exercise final reason/action/size estimates, CachyOS provenance,
Owner guards and retries, owned question data, sealed-file lifetime, allocation
failures across success/failure/removal/replacement paths, and a 1,024-package
chain. Native allocation failures are not injected. The original frozen source
and manifest are unchanged. The optional recorder checks the exact library hash,
uses private roots and `NOLOCK`, and never commits or downloads. Regular builds
and tests neither link nor load libalpm.

The execution pipeline provides transfer, filesystem preflight, hooks/scriptlets
and installed state persistence. `resolution_plans`, `downloads` and
`transactions` are enabled. Full backend equivalence still requires backend
integration and the complete interoperability/performance acceptance gates. See
[execution.md](execution.md).
