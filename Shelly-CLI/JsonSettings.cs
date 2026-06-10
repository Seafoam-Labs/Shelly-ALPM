using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly_CLI;

public class JsonSettings : CommandSettings
{
    [CommandOption("-j|--json")]
    [Description("Output results in JSON format for UI integration and scripting")]
    public bool JsonOutput { get; set; }
}
