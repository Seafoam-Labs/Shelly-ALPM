using PackageManager.Alpm;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class MarkCommand : Command<MarkPackageSettings>
{
    public override int Execute(CommandContext context, MarkPackageSettings settings)
    {
        if (Program.IsUiMode) return HandleUiMode(settings);

        if (settings.Packages.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]Error: No packages specified[/]");
            return 1;
        }

        if (settings.Explicit == settings.Depends)
        {
            AnsiConsole.MarkupLine("[red]Error: Choose exactly one of --explicit or --depends.[/]");
            return 1;
        }

        RootElevator.EnsureRootExectuion();

        var packageList = settings.Packages.ToList();
        var reasonLabel = settings.Explicit ? "explicit" : "depends";

        AnsiConsole.MarkupLine(
            $"[yellow]Packages to mark as {reasonLabel}:[/] {string.Join(", ", packageList.Select(p => p.EscapeMarkup()))}");

        if (!settings.NoConfirm && !AnsiConsole.Confirm("Do you want to proceed?"))
        {
            AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
            return 0;
        }

        using var manager = new AlpmManager();
        manager.Initialize(true);

        var allSucceeded = packageList.All(packageName => settings.Explicit
            ? manager.MarkPackageAsExplicit(packageName)
            : manager.MarkPackageAsDepend(packageName));

        if (!allSucceeded)
        {
            AnsiConsole.MarkupLine("[red]Marking failed for one or more packages. See messages above.[/]");
            return 1;
        }

        AnsiConsole.MarkupLine($"[green]Packages marked as {reasonLabel} successfully![/]");
        return 0;
    }

    private static int HandleUiMode(MarkPackageSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            UiFrames.Error("No packages specified.");
            return 1;
        }

        if (settings.Explicit == settings.Depends)
        {
            UiFrames.Error("Choose exactly one of --explicit or --depends.");
            return 1;
        }

        using var manager = new AlpmManager();
        manager.Initialize(true);

        var packageList = settings.Packages.ToList();
        var reasonLabel = settings.Explicit ? "explicit" : "depends";

        UiFrames.TxStart($"Marking packages as {reasonLabel}: {string.Join(", ", packageList)}");

        var allSucceeded = packageList.All(packageName => settings.Explicit
            ? manager.MarkPackageAsExplicit(packageName)
            : manager.MarkPackageAsDepend(packageName));

        UiFrames.TxFinish(allSucceeded, $"Packages marked as {reasonLabel} successfully!",
            "Marking failed for one or more packages.");

        return allSucceeded ? 0 : 1;
    }
}