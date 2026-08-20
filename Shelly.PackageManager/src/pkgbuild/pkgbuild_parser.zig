//! Public facade over the PKGBUILD parser implementation in `parser/`.
//! All existing call sites import this file; the implementation is split
//! across focused modules under `parser/` for readability and targeted
//! testing.

const parser = @import("parser/parser.zig");

pub const Pkgbuild = parser.Pkgbuild;
pub const PackageNames = parser.PackageNames;
pub const parsed_dep = parser.parsed_dep;
pub const split_entry = parser.split_entry;
pub const kvp = parser.kvp;
pub const dynamic_assignment = parser.dynamic_assignment;
pub const execution_step = parser.execution_step;
pub const execution_plan = parser.execution_plan;
pub const PkgbuildParser = parser.PkgbuildParser;

test {
    _ = @import("parser/parser.zig");
}
