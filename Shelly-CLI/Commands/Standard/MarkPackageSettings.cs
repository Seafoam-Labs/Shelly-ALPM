using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class MarkPackageSettings : PackageSettings
{
    [CommandOption("-e | --explicit")]
    [Description("Mark the specified packages as explicitly installed")]
    public bool Explicit { get; set; }

    [CommandOption("-d | --depends")]
    [Description("Mark the specified packages as installed as dependencies")]
    public bool Depends { get; set; }
}