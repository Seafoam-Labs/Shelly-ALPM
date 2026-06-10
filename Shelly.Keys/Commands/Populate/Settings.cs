using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly.Keys.Commands.Populate;

public class Settings : GlobalSettings
{
    [CommandArgument(0, "[keyrings]")]
    [Description("Keyring names to import (default: all in the keyrings directory).")]
    public string[] Keyrings { get; set; } = [];
    
    [CommandOption("--keyringsdir <DIR>")]
    [Description("Directory containing distribution keyrings")]
    public string KeyringsDir { get; set; } = "/usr/share/pacman/keyrings";
}