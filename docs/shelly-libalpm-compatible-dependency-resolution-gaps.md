# Shelly libalpm-Compatible Dependency Resolution Gap Analysis

## Bottom Line

Shelly does not yet have independent, libalpm-compatible dependency resolution.
It currently has a recursive AUR dependency classifier wrapped around libalpm
queries.

The decisive evidence is:

- The resolver backend exposes only “is this installed?” and “give me one
  repository satisfier,” both implemented by calling libalpm in
  `Shelly.PackageManager/src/aur/dependency_resolver.zig` and
  `Shelly.PackageManager/src/aur/manager.zig`.
- Actual recursive repository closure, reverse-dependency validation, conflict
  handling, replacement handling, and dependency ordering still happen in
  `alpm_trans_prepare()`.
- Installed/provider satisfaction directly uses `alpm_find_satisfier()`.
- Version comparison still either calls `alpm_pkg_vercmp()` or uses Shelly’s
  incompatible AUR comparer.
- The repository already acknowledges that its dependency collection is
  flattened rather than an operation-wide graph in
  `docs/shelly-isolated-root-nspawn-implementation-plan.md`.

The current Arch package is based on pacman/libalpm 7.1, so that should be the
initial compatibility target.

References:

- [Arch Linux pacman package](https://archlinux.org/packages/core/x86_64/pacman/)
- [libalpm dependency API](https://man.archlinux.org/man/libalpm_depends.3.en)
- [libalpm package API](https://man.archlinux.org/man/libalpm_packages.3.en)
- [ALPM package relations](https://man.archlinux.org/man/alpm-package-relation.7.en)
- [ALPM version algorithm](https://man.archlinux.org/man/alpm-pkgver.7.en)

## What Is Missing

### 1. A Complete Independent Package Metadata Model

Shelly needs a resolver-owned `Package` representation containing at least:

- Name, base, version, and architecture.
- Repository and repository priority.
- Runtime dependencies.
- Provides, conflicts, and replaces.
- Groups.
- Installation reason.
- Installed versus repository versus local archive versus AUR origin.
- Filename, download size, and install size where the plan exposes them.
- For AUR packages: runtime, make, and check dependencies per split-package
  output.
- The reviewed AUR commit and package-base identity.

The current `RepoDependency` contains only a name and role. That is too little
information to evaluate a transaction.

### 2. Independent Metadata Readers

If “without calling libalpm” is strict, Shelly must read package state itself:

- Parse synchronized repository `.db` archives and their `desc` entries.
- Parse `/var/lib/pacman/local/*/desc` for installed state.
- Parse `.PKGINFO` from local package archives.
- Fully parse `.SRCINFO` for AUR metadata.
- Preserve repository ordering and `Usage` settings from configuration.
- Load `IgnorePkg`, `IgnoreGroup`, architecture, and `AssumeInstalled`.

Shelly’s archive reader is reusable, but currently only detects packages; it
does not extract a resolver-ready `.PKGINFO`. Its `.SRCINFO` parser currently
reads only `pkgbase` and `pkgname`, not dependencies, versions, architecture,
provides, conflicts, or split-package overrides.

### 3. A libalpm-Compatible Relation Parser

Implement a standalone parser for:

- Unversioned relations.
- `=`, `<`, `<=`, `>`, and `>=`.
- Epoch-bearing versions without mistaking `:` for an optional-dependency
  description.
- Optional-dependency descriptions.
- Versioned `provides`.
- Soname relations such as `lib:...`.
- Malformed input with explicit errors.

The current PKGBUILD parser falls back to treating malformed or unsupported
expressions as an unversioned name. That is unsafe for a resolver.

### 4. An Exact `alpm_pkg_vercmp` Reimplementation

Shelly’s AUR comparer is not libalpm-compatible:

- It invents a missing pkgrel of `"0"`. Libalpm ignores pkgrel when only one
  side has it, so libalpm considers `1.0` and `1.0-1` equal.
- It assigns special semantic ordering to `dev`, `git`, `alpha`, `beta`, `rc`,
  and similar strings; libalpm does not use that scheme.
- It compares alphabetic segments case-insensitively.
- Numeric segments overflow `i64` and then fall back to string comparison.
- Unknown operators return `true`.

This must be completed before any satisfier result can be trusted.

### 5. Exact Package and Provision Satisfaction Semantics

Implement the equivalent of libalpm’s dependency comparison:

- Match the real package name against the package version.
- Otherwise inspect every `provides` entry.
- An unversioned dependency may be satisfied by an unversioned or versioned
  provision.
- A versioned dependency may only be satisfied by a versioned provision.
- Compare the provision’s declared version, not the provider package’s version.
- Match names case-sensitively.
- Support `AssumeInstalled`.

Shelly currently checks an AUR provider’s package version rather than the
matching `provides` version.

### 6. Satisfier Indexes

Build independent indexes for:

- Exact package name.
- Provided name.
- Group name.
- Installed package name and provisions.
- Repository package name and provisions.
- AUR split-package names and provisions.

Every index entry must retain the exact provision expression and source
priority. Returning only the real package name loses information needed for
diagnostics and constraint reconciliation.

### 7. libalpm-Compatible Candidate Selection

Reproduce these selection rules:

1. Exact literal package matches before providers.
2. Repositories in configured order.
3. Respect repository `Usage`.
4. Respect ignored packages and groups.
5. Exclude packages already selected or removed.
6. Prefer an already-installed provider when libalpm would.
7. If several providers remain, generate a provider-selection question.
8. Preserve the chosen provider so the answer remains stable during the solve.

### 8. An Operation-Wide Constraint Graph

Replace the current per-target flattened collections with one graph for the
entire operation.

Each edge needs:

- Requiring package.
- Original dependency expression.
- Selected satisfying package.
- Exact matching name or provision.
- Runtime, build, or check role.
- Source: installed, repository, local archive, or AUR.
- Split-package output.
- Whether the dependency is already satisfied.

Nodes should be actual package identities, not dependency strings.

Current deduplication discards constraints:

- Repository dependencies are merged solely by resulting package name.
- AUR nodes are merged solely by package base and commit.
- The graph does not retain all expressions that the selected package must
  satisfy.

### 9. Recursive Repository Closure

Shelly must independently walk the runtime dependencies of every newly selected
repository or local package until reaching a fixed point.

The resolver must account for:

- Already selected packages satisfying later edges.
- Explicit top-level targets being preferred as satisfiers.
- Installed packages left untouched by the transaction.
- Installed packages being upgraded, replaced, or removed no longer satisfying
  dependencies.
- Duplicate targets.
- Mixed repository and local-package transactions.
- Failure rollback so a partially explored target does not contaminate the
  plan.
- Complete missing-dependency diagnostics.

Right now Shelly lists direct repository dependencies and relies on
`alpm_trans_prepare()` to pull their transitive dependencies.

### 10. Correct AUR Graph Resolution

The existing recursion needs these corrections:

- Resolve all requested packages in one shared graph.
- Use full `.SRCINFO`, including package-base and split-package sections.
- Map every edge to the exact split output satisfying it.
- Validate `provides` expressions, including their versions.
- Combine every constraint placed on a shared dependency.
- Detect incompatible constraints.
- Do not use host-installed AUR packages as evidence that a clean build root is
  satisfied.
- Distinguish runtime, build, and check roles transitively.
- Build in dependency order.
- Reject genuinely unbuildable AUR cycles.

Current resolution can silently omit hard dependencies when provider lookup
fails or a version is unsuitable. Hard dependency failure must be fatal.

### 11. Post-Removal and Post-Upgrade State Simulation

A real resolver evaluates the state that will exist after the transaction, not
the current installed database.

It must construct:

```text
future state =
    installed packages
  - explicit removals
  - replaced packages
  - old versions of upgraded packages
  + selected transaction packages
```

Then every hard dependency in that future state must still have a satisfier.

This is the missing equivalent of libalpm’s forward and reverse
`alpm_checkdeps()` checks.

### 12. Conflict Resolution

Implement both directions:

- Target versus target.
- Target versus installed package.
- Installed package versus target.
- Versioned conflicts.
- Conflicts through `provides`.
- Conflicts already covered by a planned removal.
- Provider packages that conflict with each other.
- User questions for removable installed conflicts.
- Fatal target-target conflicts where neither target supersedes the other.

Parsing `conflicts` without applying it does not produce an executable plan.

### 13. Replacement Semantics

Implement:

- Versioned `replaces`.
- Repository-priority behavior.
- Replacement questions.
- Transfer of explicit/dependency installation reason.
- One replacement removing the old package.
- A replacement already selected by another edge.
- Replacement processing during system upgrades.
- Interaction between replacements, conflicts, and future dependency
  satisfaction.

### 14. Final Dependency Validation

After closure, provider selection, replacements, and conflict removals, perform
a fresh validation pass over the complete future state.

It should report structured errors containing:

- Requiring package.
- Missing expression.
- Package whose removal or upgrade caused the breakage.
- Candidates considered and why they were rejected.

No `catch false`, `catch null`, or `continue` may convert an internal, database,
or network failure into “not installed,” “not in repository,” or “dependency
can be skipped.” The current adapter does exactly that.

### 15. Dependency Ordering and Cycle Behavior

Generate deterministic installation and removal order from the resolved graph.

For strict libalpm compatibility:

- Repository dependency cycles are not automatically fatal.
- Libalpm emits a cycle warning and chooses a deterministic order.
- Removal order is the reverse dependency order.
- Installed packages can participate in ordering without becoming transaction
  targets.

AUR source-build cycles may still need to be rejected because neither package
can be built first. That is a build-system restriction, distinct from libalpm
transaction semantics.

### 16. Transaction-Flag Compatibility

The solve must honor all dependency-affecting flags:

- `NODEPS`
- `NODEPVERSION`
- `NOCONFLICTS`
- `NEEDED`
- `ALLDEPS`
- `ALLEXPLICIT`
- `CASCADE`
- `RECURSE`
- `RECURSEALL`
- `UNNEEDED`

Shelly exposes these flags, but libalpm currently interprets them.

### 17. Removal Resolution

For complete package-manager compatibility, implement:

- Refuse removals that break dependencies.
- Cascade removal of reverse dependants.
- Recursive dependency removal.
- Difference between dependency-installed and explicit packages.
- Preservation of packages still required through another name or provision.
- Optional-dependency preservation policy.
- Circular removal graphs.
- `AssumeInstalled`.

This is separate from install closure but necessary before Shelly can claim
independent dependency resolution for all operations.

### 18. Update and System-Upgrade Resolution

Implement independently:

- Exact-name upgrade lookup.
- Epoch, pkgver, and pkgrel comparison.
- Repository priority.
- Upgrade versus permitted downgrade.
- Ignored packages and groups.
- Replacements discovered during system upgrades.
- Partial target updates and their reverse-dependency consequences.
- Packages disappearing from repositories.
- Provider changes between installed and new versions.
- Full-system transaction closure.

### 19. A Stable Resolver Result Contract

The pure resolver should return a complete immutable plan containing:

- Packages to install, upgrade, and downgrade.
- Packages to remove.
- Packages left unchanged as satisfiers.
- Dependency edges and selected provisions.
- Install and removal order.
- Installation reasons.
- Provider, replacement, and conflict questions.
- Warnings.
- Structured fatal errors.

Execution should consume this plan without asking libalpm to change its package
set.

### 20. Differential Compatibility Tests

This is essential to substantiate “libalpm-compatible.”

Add:

- A frozen `vercmp` corpus, including epochs, missing pkgrel, huge numeric
  segments, and separator cases.
- Relation and parser tests.
- Versioned and unversioned `provides` matrices.
- Multiple-provider and repository-priority cases.
- Upgrade-removes-old-provider cases.
- Conflict and replacement matrices.
- Reverse-dependency checks.
- Cycles and ordering.
- Removal flag combinations.
- Split-package AUR cases.
- Soname dependencies.
- Malformed metadata and error propagation.
- Randomized small package universes.

During development, compare Shelly’s plan against libalpm 7.1 as a test-only
oracle. If even tests must never call libalpm, generate and commit frozen
expected fixtures from upstream’s pactest suite.

## What Shelly Already Has That Can Be Reused

Shelly is not starting from zero. It already has:

- Runtime, build, and check role labels.
- Recursive AUR discovery scaffolding.
- AUR RPC metadata.
- Provider-selection UI machinery.
- Configuration parsing for repository usage, ignore rules, and architecture.
- A tar, zstd, and gzip archive reader.
- Package operation plans and structured UI questions.
- Some package metadata snapshots.
- A documented design for an operation-wide AUR DAG.

Those are useful supporting pieces, but none currently constitutes the
authoritative solver.

## Practical Definition of Done

Shelly has true independent resolution when, given identical local metadata,
synchronized databases, configuration, targets, and flags, it produces the same
successful package set—or the same class of failure and required questions—as
libalpm 7.1, without invoking:

- `alpm_find_satisfier`
- `alpm_find_dbs_satisfier`
- `alpm_pkg_vercmp`
- `alpm_checkdeps`
- `alpm_sync_get_new_version`
- `alpm_sync_sysupgrade`
- Dependency, conflict, or replacement behavior inside `alpm_trans_prepare`

Downloads, signature validation, file-conflict checks, hooks, scriptlets, and
filesystem commit are separate transaction-engine work. They are not required
merely to claim an independent dependency resolver, although removing libalpm
from Shelly entirely would require replacing those too.
