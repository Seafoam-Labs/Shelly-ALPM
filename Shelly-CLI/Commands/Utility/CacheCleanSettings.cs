using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Utility;

public class CacheCleanSettings : CommandSettings
{
    [CommandOption("-r | --remove")]
    [Description("Removes all candidate entries")]
    public bool Remove { get; set; }
    
    [CommandOption("-k | --keep")]
    [CommandArgument(0, "<keep>")]
    [Description("Number of versions to keep")]
    public int Keep { get; set; } = 3;

    [CommandOption("-u | --uninstalled")]
    [Description("target uninstalled packages")]
    public bool Uninstalled { get; set; } = false;
    
    [CommandOption("-d | --dry-run")]
    [Description("Show what would be removed")]
    public bool DryRun { get; set; } = false;

    [CommandOption("-c | --cache-dir")]
    [CommandArgument(0, "<cache-dir>")]
    [Description("Path to the cache directory")]
    public string? CacheDir { get; set; } = "/var/cache/pacman/pkg";

    [CommandOption("-t | --target <packages>")]
    [Description("Removes all cached entries related to the selected package")]
    public string[] Packages { get; set; } = [];

    [CommandOption("--no-confirm")]
    [Description("Skips confirmation checks if true")]
    public bool NoConfirm { get; set; }
}