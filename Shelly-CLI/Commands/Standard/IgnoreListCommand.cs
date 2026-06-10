using System.Text;
using System.Text.Json;
using PackageManager.Alpm;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class IgnoreListSettings : JsonSettings;

public class IgnoreListCommand : Command<IgnoreListSettings>
{
    public override int Execute(CommandContext context, IgnoreListSettings settings)
    {
        using var manager = new AlpmManager();
        var ignoredPackages = manager.GetIgnoredPackages();

        if (Program.IsUiMode)
        {
            UiFrames.Frame(ignoredPackages);
            UiFrames.Info(ignoredPackages.Count == 0
                ? "IgnorePkg list is empty."
                : $"Total: {ignoredPackages.Count} ignored packages");
            return 0;
        }

        if (settings.JsonOutput)
        {
            var json = JsonSerializer.Serialize(ignoredPackages, ShellyCLIJsonContext.Default.ListString);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, Encoding.UTF8);
            writer.WriteLine(json);
            writer.Flush();
            return 0;
        }

        if (ignoredPackages.Count == 0)
        {
            AnsiConsole.MarkupLine("[yellow]IgnorePkg list is empty.[/]");
            return 0;
        }

        foreach (var package in ignoredPackages)
            AnsiConsole.WriteLine(package);

        return 0;
    }
}