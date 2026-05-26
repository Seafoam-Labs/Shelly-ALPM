using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class DowngradePackageCommandSettings : PackageSettings
{
    [CommandOption("-o | --oldest")]
    [Description("Installs the oldest matched version")]
    public bool UseOldest { get; set; }

    [CommandOption("-l | --latest")]
    [Description("Installs the newest matched version")]
    public bool UseNewest { get; set; }

    [CommandOption("-i | --ignore")]
    [Description("Add to IgnorePkg list")]
    public bool AddIgnore { get; set; }
}