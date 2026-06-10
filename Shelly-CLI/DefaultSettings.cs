using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI;

public class DefaultSettings : JsonSettings
{
    [CommandOption("-y|--sync")]
    [Description("Synchronize package databases before performing the operation")]
    public bool Sync { get; set; }

    [CommandOption("--singlepane")]
    [Description("Use pacman-style single-stream output instead of the split-pane Live layout")]
    public bool SinglePane { get; set; }
}