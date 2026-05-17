using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class RemovePackageSettings : PackageSettings
{
    [CommandOption("-c | --cascade")]
    [Description("Removes all things the removed package(s) are dependent on that have no other uses")]
    public bool Cascade { get; set; }

    [CommandOption("-o | --opt-deps")]
    [Description("Removes optional dependencies installed with the package, that don't depend on other packages")]
    public bool OptDeps { get; set; }

    [CommandOption("-i | --ripple")]
    [Description("Removes packages that depend on the package being removed")]
    public bool Ripple { get; set; }

    [CommandOption("-r | --remove-config")]
    [Description(
        "Removes any files in your ~/.config that can be tied exclusively to the removed package(s). This is EXPERIMENTAL and has no guarantees of working")]
    public bool RemoveConfig { get; set; }
}