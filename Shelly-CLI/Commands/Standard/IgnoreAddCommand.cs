using System.ComponentModel;
using PackageManager.Alpm;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class IgnoreAddSettings : CommandSettings
{
    [CommandArgument(0, "<packages>")]
    [Description("One or more package names to add to IgnorePkg (space-separated)")]
    public string[] Packages { get; set; } = [];
}

public class IgnoreAddCommand : Command<IgnoreAddSettings>
{
    public override int Execute(CommandContext context, IgnoreAddSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            if (Program.IsUiMode)
                UiFrames.Error("No packages specified");
            else
                AnsiConsole.MarkupLine("[red]Error: No packages specified[/]");

            return 1;
        }

        if (!Program.IsUiMode)
            RootElevator.EnsureRootExectuion();

        try
        {
            using var manager = new AlpmManager();
            manager.IgnorePackages(settings.Packages);

            var formattedPackages = string.Join(", ", settings.Packages);
            if (Program.IsUiMode)
                UiFrames.Info($"Added to IgnorePkg list: {formattedPackages}");
            else
                AnsiConsole.MarkupLine(
                    $"Added to IgnorePkg list: [green]{formattedPackages.EscapeMarkup()}[/]");

            return 0;
        }
        catch (Exception e)
        {
            if (Program.IsUiMode)
                UiFrames.Error($"Failed to add to IgnorePkg list: {e.Message}");
            else
                AnsiConsole.MarkupLine($"[red]Error: {e.Message.EscapeMarkup()}[/]");

            return 1;
        }
    }
}