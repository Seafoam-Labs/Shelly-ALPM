using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI;

public class DefaultSettings : CommandSettings
{
    [CommandOption("-j|--json")]
    [Description("Output results in JSON format for UI integration and scripting")]
    public bool JsonOutput { get; set; }

    [CommandOption("-y|--sync")]
    [Description("Synchronize package databases before performing the operation")]
    public bool Sync { get; set; }

    [CommandOption("--singlepane")]
    [Description("Use pacman-style single-stream output instead of the split-pane Live layout")]
    public bool SinglePane { get; set; }
}