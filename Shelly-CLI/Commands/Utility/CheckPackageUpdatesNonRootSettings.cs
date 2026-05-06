using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Utility;

public class CheckPackageUpdatesNonRootSettings : ForceSettings
{
    [CommandOption("-a | --aur")]
    [Description("Pass this setting if aur should be checked.")]
    public bool CheckAur { get; set; }

    [CommandOption("-l | --flatpak")]
    [Description("Pass this setting if flatpak should be checked.")]
    public bool CheckFlatpak { get; set; }
    
    [CommandOption("-c | --count")]
    [Description("Returns the number of updates.")]
    public bool Count { get; set; }
}