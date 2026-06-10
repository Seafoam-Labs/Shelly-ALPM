using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class DowngradePackageCommandSettings : PackageSettings
{
    [CommandOption("-o | --oldest")]
    [Description("Installs the oldest matched version (default newest)")]
    public bool UseOldest { get; set; }

    [CommandOption("-i | --ignore")]
    [Description("Add to IgnorePkg list")]
    public bool AddIgnore { get; set; }

    [CommandOption("--list-options")]
    [Description("List available downgrade versions")]
    public bool ListOptions { get; set; }

    [CommandOption("-t | --target")]
    [Description("Install a specific downgrade target by exact version or package filename")]
    public string? Target { get; set; }
}