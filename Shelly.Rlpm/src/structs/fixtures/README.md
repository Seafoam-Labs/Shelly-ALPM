# Version comparison fixtures

`version_comparisons.zig` records 54 input pairs and result signs from
`alpm_pkg_vercmp`. Empty and unusual inputs deliberately exercise comparison,
independently of metadata validation. The original 13 valid-version examples
remain in `Version.zig`.

Generated on 2026-09-23 with Python `ctypes.CDLL("libalpm.so.16")`, calling
`alpm_pkg_vercmp` with two `c_char_p` arguments and a `c_int` result, normalized
to `-1`, `0`, or `1`. Inputs were explicitly selected regression/boundary cases;
expected results were obtained from the library, not RLPM.

Oracle provenance:

- Installed package: `pacman 7.1.0.r9.g54d9411-4`, x86_64, from CachyOS.
- Library version: `16.0.1`.
- Upstream revision identified by the package version: `54d9411` in
  [pacman](https://gitlab.archlinux.org/pacman/pacman/-/tree/54d9411).
- `/usr/lib/libalpm.so.16.0.1` SHA-256:
  `da30edd45277cf4b1000485658976042f8106fe0b97378d1e6c4e81a9d7c4888`.
- Package `.BUILDINFO` PKGBUILD SHA-256:
  `1ca93466764e2ab223ba231780c513f097ba95a511010fa49a2a46a87a06d5af`.

This pins the actual binary used for the results. It is a downstream build,
not an independently built pristine upstream oracle. Fetching the pinned upstream
source was unavailable in the implementation environment, so the package's
abbreviated upstream revision is recorded without claiming a verified full source
commit or absence of downstream changes.

From `Shelly.Rlpm`, run:

```sh
zig build test-version
zig build test-version-compat
```

The first command is hermetic and does not link libalpm. The second explicitly
links the installed library, checks its reported version, checks the frozen
results, crosses all fixture inputs, and generates 20,000 reproducible pairs
using seed `0x524c504d` with Zig 0.16's `DefaultPrng`. Generated pairs cover
structured epoch/pkgver/pkgrel strings, arbitrary NUL-free ASCII, and mutations
of related strings. Failures print the inputs as bytes, both results, and the
generation seed/iteration. Keep minimized failures as new frozen cases.

The live test checks the library version, not its binary hash: another build of
16.0.1 can be tested for compatibility, but it is not automatically the original
fixture oracle. When intentionally updating the oracle, record package/revision
and binary provenance, review changed results, then update the version assertion
and fixtures together. Do not silently regenerate expectations from RLPM.

Compatibility covers ASCII, NUL-free strings. Non-ASCII, embedded NUL, and null
C pointers are outside the contract. Do not infer transitive equality for versions
with omitted pkgrel: `1.0` equals both `1.0-1` and `1.0-2`, but the latter pair
compares unequally.
