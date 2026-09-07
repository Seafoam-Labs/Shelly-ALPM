const types = @import("types.zig");

const flag = types.flag;
const stringOption = types.stringOption;

pub const variants = [_]types.Variant{
    .{
        .action = .utility,
        .name = "utility",
        .default_for_action = true,
        .description = "Run Shelly maintenance, pacnew/pacsave management, and command-catalog generators.",
        .implementation = "Native Zig ownership repair; Zigalpm.PacfileManager pacdiff workflow; Markdown documentation and Bash/Fish/Zsh completion generators",
        .options = &.{
            flag("--fix-permissions", &.{"-f"}, "Restore the invoking user's ownership of Shelly's configuration, cache, and data directories"),
            flag("--repair-db", &.{"-r"}, "Remove a stale database lock"),
            flag("--docs", &.{"-d"}, "Write Markdown CLI reference documentation to standard output"),
            .{
                .name = "--completions",
                .aliases = &.{"-c"},
                .type = "string",
                .minimumArity = 1,
                .maximumArity = 1,
                .description = "Write a Bash, Fish, or Zsh completion script to standard output",
                .choices = &.{ "bash", "fish", "zsh" },
            },
            flag("--pacfiles", &.{"-p"}, "Run the pacdiff-compatible pacnew, pacorig, and pacsave maintenance workflow"),
            flag("--find", &.{"-F"}, "Recursively find pacfiles instead of reading the local package database"),
            flag("--locate", &.{"-l"}, "Find pacfiles with locate instead of reading the local package database"),
            flag("--pacmandb", &.{"-P"}, "Search backup paths from the local package database (default)"),
            flag("--backup", &.{"-b"}, "Save the old original as .bak before overwriting"),
            stringOption("--cachedir", &.{"-C"}, "Package cache directory for three-way base archives; repeat to add directories", false),
            flag("--output", &.{"-o"}, "Print discovered pacfile paths without modifying them"),
            flag("--sudo", &.{"-s"}, "Explicitly request elevation; interactive pacfile maintenance elevates automatically"),
            flag("--threeway", &.{"-3"}, "Use a cached older package as the third input when viewing differences"),
            flag("--nocolor", &.{}, "Disable colored pacfile status output"),
            stringOption("--search-path", &.{}, "Path to scan with --find; repeat to add paths", false),
            stringOption("--diff-program", &.{}, "Diff command, overriding DIFFPROG", false),
            stringOption("--merge-program", &.{}, "Merge command, overriding MERGEPROG", false),
        },
    },
};
