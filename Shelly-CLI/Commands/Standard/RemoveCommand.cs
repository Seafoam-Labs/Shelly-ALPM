using PackageManager.Alpm;
using PackageManager.Wire;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Shelly.Utilities.Eventing;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class RemoveCommand : AsyncCommand<RemovePackageSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, RemovePackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeRemove(settings);
        }

        if (settings.Packages.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]Error: No packages specified[/]");
            return 1;
        }

        RootElevator.EnsureRootExectuion();
        var packageList = settings.Packages.ToList();

        AnsiConsole.MarkupLine($"[yellow]Packages to remove:[/] {string.Join(", ", packageList.Select(p => p.EscapeMarkup()))}");

        if (!settings.NoConfirm)
        {
            if (!AnsiConsole.Confirm("Do you want to proceed?"))
            {
                AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
                return 0;
            }
        }

        using var manager = new AlpmManager();

        AnsiConsole.MarkupLine("[yellow]Initializing ALPM...[/]");
        manager.Initialize(true);

        AnsiConsole.MarkupLine("[yellow]Removing packages...[/]");


        var flags = AlpmTransFlag.None;
        if (settings.Cascade)
        {
            flags |= AlpmTransFlag.NoSave | AlpmTransFlag.Recurse;
        }
        else if (settings.Ripple)
        {
            flags |= AlpmTransFlag.Cascade;
        }
        
        var result = await StandardSinglePaneOutput.Output(manager, x => x.RemovePackages(packageList, flags,settings.OptDeps), settings.NoConfirm);

        if (settings.RemoveConfig)
        {
            HandleConfigRemoval(settings.Packages);
        }

        if (!result)
        {
            AnsiConsole.MarkupLine("[red]Removal failed. See errors above.[/]");
            return 1;
        }
        AnsiConsole.MarkupLine("[green]Packages removed successfully![/]");
        return 0;
    }

    private static int HandleConfigRemoval(string[] packageNames)
    {
        foreach (var package in packageNames)
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), package);
            try
            {
                Directory.Delete(path, true);
            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to find directory for {package} moving on");
            }
        }

        return 0;
    }

    private static async Task<int> HandleUiModeRemove(RemovePackageSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, "No packages specified"));
            return 1;
        }

        var flags = AlpmTransFlag.None;
        if (settings.Cascade)
            flags |= AlpmTransFlag.NoSave | AlpmTransFlag.Recurse;
        else if (settings.Ripple)
            flags |= AlpmTransFlag.Cascade;

        using var manager = new AlpmManager();
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, settings.NoConfirm);
        manager.Initialize(true);

        var packageList = settings.Packages.ToList();
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            AlpmEvents.TransactionStart,
            $"Removing packages: {string.Join(", ", packageList)}"));

        var ok = await UiModeOutput.Run(manager,
            m => m.RemovePackages(packageList, flags, settings.OptDeps));

        if (settings.RemoveConfig)
            HandleConfigRemoval(settings.Packages);

        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            ok ? AlpmEvents.TransactionDone : AlpmEvents.TransactionFailed,
            ok ? "Packages removed successfully!" : "Removal failed."));
        return ok ? 0 : 1;
    }
}