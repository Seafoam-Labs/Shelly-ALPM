using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI;

public class ListSettings : DefaultSettings
{
    [CommandOption("-s|--sort <SORT>")]
    [Description("Sort results by: name, size, popularity (popularity sorts by name for non-aur packages)")]
    [DefaultValue(SortOption.Name)]
    public SortOption Sort { get; set; } = SortOption.Name;

    [CommandOption("-o|--order <ORDER>")]
    [Description("Sort order: ascending, descending (default: ascending")]
    [DefaultValue(SortDirection.Ascending)]
    public SortDirection Order { get; set; } = SortDirection.Ascending;

    [CommandOption("-f|--filter <FILTER>")]
    [Description("Filter packages by name (case-insensitive fuzzy match)")]
    public string? Filter { get; set; }

    [CommandOption("-p|--page <PAGE>")]
    [Description("The page to render")]
    public int Page { get; set; } = 1;

    [CommandOption("-t|--take <TAKE>")]
    [Description("The number of packages to render per page")]
    public int Take { get; set; } = 100;
}

public class AlpmListSettings : ListSettings
{
    [CommandOption("--show-hidden")]
    [Description("Show packages that are in the IgnorePkg list in pacman.conf")]
    [DefaultValue(false)]
    public bool ShowHidden { get; init; } = false;
}
