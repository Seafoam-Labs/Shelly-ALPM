using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly.Keys.Commands.Initialize;

public class Settings : GlobalSettings
{
    [CommandArgument(0, "[directory]")]
    [Description("The directory to initialize the keyring in")]
    //TODO: Change this to a shelly value when/if we remove pacman from a build
    public string Directory { get; set; } = "/etc/pacman.d/gnupg";
}