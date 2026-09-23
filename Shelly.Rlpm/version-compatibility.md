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
zig build test-version-compat
zig build test
```

The first step runs 13 hermetic tests, including ownership/allocation checks and
54 frozen comparison fixtures. The opt-in compatibility step links libalpm only
into a separate test executable. It checks the fixtures, 2,916 cross-corpus pairs,
and 20,000 deterministic generated pairs, including full epoch/pkgver/pkgrel
strings and arbitrary NUL-free ASCII. Normal builds/tests do not link libalpm.

On 2026-09-23 with Zig 0.16.0, the focused step and all 14 tests in the differential
executable passed. The full RLPM library runner reported 43 passed and 5 failed;
all failures were pre-existing GPG fixture startup failures (`gpg-agent` could
not start), before signature assertions. Both executable template tests passed.

The oracle was CachyOS's libalpm 16.0.1. See
[fixture provenance](src/structs/fixtures/README.md) for the exact package and
binary hash, reproducibility details, and the limitation that pristine upstream
source verification was unavailable. The corpus is compatibility evidence, not
an exhaustive proof. Embedded NUL, non-ASCII, and nullable C pointers are outside
the declared compatibility contract.
