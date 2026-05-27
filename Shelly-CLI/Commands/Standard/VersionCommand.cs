using System.Diagnostics.CodeAnalysis;
using System.Reflection;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class VersionCommand : Command
{
    public override int Execute([NotNull] CommandContext context)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeVersion();
        }

        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(4) ?? "unknown";
        AnsiConsole.MarkupLine($"[bold]shelly[/] version [green]{version}[/]");
        return 0;
    }

    private static int HandleUiModeVersion()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(4) ?? "unknown";
        Console.WriteLine($"shelly version {version}");
        return 0;
    }
}
