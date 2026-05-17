using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class InstallLocalPackageSettings : CommandSettings
{
    [CommandOption("-l | --location")]
    [Description("Location of the .pkg.tar.gz(zst) to be installed")]
    public required string PackageLocation { get; init; }

    [CommandOption("-n|--no-confirm")]
    [Description("Proceed without asking for user confirmation")]
    public bool NoConfirm { get; set; }

    [CommandOption("--singlepane")]
    [Description("Use pacman-style single-stream output instead of the split-pane Live layout")]
    public bool SinglePane { get; set; }
}
