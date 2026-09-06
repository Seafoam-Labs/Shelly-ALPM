const types = @import("types.zig");

pub const variants = [_]types.Variant{.{
    .action = .resolve,
    .name = "resolve",
    .default_for_action = true,
    .description = "Resolves exact standard or AUR package names to package bases without mutating package state",
    .options = &.{
        .{
            .name = "--source",
            .type = "string",
            .minimumArity = 1,
            .maximumArity = 1,
            .description = "Resolution source: auto, standard, or aur",
            .choices = &.{ "auto", "standard", "aur" },
        },
        types.stringOption("--repository", &.{}, "Permits a standard repository; repeatable", false),
    },
    .arguments = &.{types.repeatedArgument("name", 1, "Exact binary package names to resolve in input order")},
}};
