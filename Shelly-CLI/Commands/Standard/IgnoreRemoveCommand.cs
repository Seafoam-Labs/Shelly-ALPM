using System.ComponentModel;
using PackageManager.Alpm;
using PackageManager.Wire;
using Shelly_CLI.Utility;
using Shelly.Utilities.Eventing;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class IgnoreRemoveSettings : CommandSettings
{
    [CommandArgument(0, "<packages>")]
    [Description("One or more package names to remove from IgnorePkg (space-separated)")]
    public string[] Packages { get; set; } = [];
}

public class IgnoreRemoveCommand : Command<IgnoreRemoveSettings>
{
    public override int Execute(CommandContext context, IgnoreRemoveSettings settings)
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
            manager.UnignorePackages(settings.Packages);

            var formattedPackages = string.Join(", ", settings.Packages);
            if (Program.IsUiMode)
                UiFrames.Info($"Removed from IgnorePkg list: {formattedPackages}");
            else
                AnsiConsole.MarkupLine(
                    $"Removed from IgnorePkg list: [green]{formattedPackages.EscapeMarkup()}[/]");

            return 0;
        }
        catch (Exception e)
        {
            if (Program.IsUiMode)
                UiFrames.Error($"Failed to remove from IgnorePkg list: {e.Message}");
            else
                AnsiConsole.MarkupLine($"[red]Error: {e.Message.EscapeMarkup()}[/]");

            return 1;
        }
    }
}