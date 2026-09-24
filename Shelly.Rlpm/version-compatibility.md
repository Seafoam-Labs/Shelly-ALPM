# Version parsing and comparison

`Shelly_Rlpm.Version` separates metadata construction from raw comparison.

```zig
const Version = @import("Shelly_Rlpm").Version;

// Owned metadata, with structural validation and no numeric epoch limit.
var version = try Version.init("18446744073709551616:1.0-1", allocator);
defer version.deinit(allocator);
// version.epoch is the string "18446744073709551616".

// Allocation-free comparison; inputs do not need to pass metadata validation.
const result = Version.compareStrings(":1.0", "1.0"); // .equal
```

`compareStrings` follows libalpm's ordering for ASCII, NUL-free strings, including
empty inputs, empty components, and unusual colon/hyphen placement. An epoch is
recognized only at an initial digit sequence followed by `:`; an initial colon
uses epoch zero. Numeric runs are compared without integer conversion. pkgrel
is compared only if both inputs supply one. `compareVersions` uses the same
comparison routine for already-constructed values.

`validate` and `init` deliberately impose stronger metadata checks. They reject
empty versions/components and non-digit epoch prefixes, including signs and
underscores. They are structural validators, not a complete implementation of
PKGBUILD's version grammar. Missing pkgrel and internal hyphens remain supported.
`InvalidVersion` and `InvalidCharacter` describe validation failures; numeric
epoch overflow is no longer possible.

## API migration and ownership

`epoch` changed from `u64` to `[]const u8`. Compare its value with string operations,
or use the version comparison APIs for ordering. Explicit leading zeros are
preserved; missing epochs expose `"0"`.

`init` owns one copy of `raw`. The parsed components borrow slices of that buffer,
except the static default epoch. `deinit` frees only `raw`. Do not free components
individually or call `deinit` on multiple shallow copies of the same value.

Results retain their numeric values: less = `-1`, equal = `0`, greater = `1`.
Equality across omitted releases is not transitive: `1.0` equals both `1.0-1` and
`1.0-2`, while `1.0-1` is less than `1.0-2`.

## Verification

From this directory:

```sh
zig build test-version
zig build test
```

The first step runs the 13 tests in `src/structs/Version.zig`, including
ownership/allocation checks, the original 13 valid-version examples, and 54
additional comparison cases with fixed expected results. Those cases also check
reverse ordering, reflexivity, and the owned-value comparison path for inputs
that pass metadata validation. They cover large epochs, empty components,
unusual syntax, numeric runs, case sensitivity, and separator behavior.

All version tests live in `Version.zig` and run without linking or invoking
libalpm. The separate fixture files and live differential test target were removed
on 2026-09-24; the 54 recorded input pairs and expected results were retained
unchanged in the version test. The full `test` step includes these tests too.

## Expected-result provenance

The 54 additional expected signs were recorded on 2026-09-23 by calling
`alpm_pkg_vercmp` through Python ctypes and normalizing results to `-1`, `0`, or
`1`. Expectations came from libalpm, not the RLPM implementation:

- Package: CachyOS `pacman 7.1.0.r9.g54d9411-4`, x86_64; libalpm `16.0.1`.
- Upstream revision identified by the package version: `54d9411`.
- Library SHA-256:
  `da30edd45277cf4b1000485658976042f8106fe0b97378d1e6c4e81a9d7c4888`.
- Package `.BUILDINFO` PKGBUILD SHA-256:
  `1ca93466764e2ab223ba231780c513f097ba95a511010fa49a2a46a87a06d5af`.

This identifies the downstream build used for the original results. Independent
verification of pristine upstream source was unavailable. The fixed examples
are compatibility evidence, not an exhaustive proof. Embedded NUL, non-ASCII,
and nullable C pointers are outside the declared compatibility contract.
