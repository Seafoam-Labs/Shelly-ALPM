using PackageManager.Alpm;
using PackageManager.Wire;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Shelly.Utilities.Eventing;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class InstallCommand : AsyncCommand<InstallPackageSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, InstallPackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeInstall(context, settings);
        }

        if (settings.Packages.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]Error: No packages specified[/]");
            return 1;
        }

        RootElevator.EnsureRootExectuion();

        var packageList = settings.Packages.ToList();

        AnsiConsole.MarkupLine(
            $"[yellow]Packages to install:[/] {string.Join(", ", packageList.Select(p => p.EscapeMarkup()))}");
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
        
        Task<bool> RunOutput(IAlpmManager m, Func<IAlpmManager, Task<bool>> op, bool nc) => StandardSinglePaneOutput.Output(m, op, nc);

        if (settings.Upgrade)
        {
            AnsiConsole.Markup("[yellow]Running system upgrade[/yellow]");
            var upgradeResult = await RunOutput(manager, x => x.SyncSystemUpdate(), settings.NoConfirm);
            if (!upgradeResult)
            {
                AnsiConsole.MarkupLine("[red]System upgrade failed. See errors above.[/]");
                return 1;
            }
        }

        if (settings.BuildDepsOn)
        {
            if (settings.Packages.Length > 1)
            {
                AnsiConsole.MarkupLine("[yellow]Cannot build dependencies for multiple packages at once.[/]");
                return 0;
            }

            if (settings.MakeDepsOn)
            {
                AnsiConsole.MarkupLine("[yellow]Installing packages...[/]");
                var result = await RunOutput(manager,
                    x => x.InstallDependenciesOnly(packageList.First(), true),
                    settings.NoConfirm);
                if (!result)
                {
                    AnsiConsole.MarkupLine("[red]Installation failed. See errors above.[/]");
                    return 1;
                }

                return 0;
            }

            AnsiConsole.MarkupLine("[yellow]Installing packages...[/]");
            var depsResult = await RunOutput(manager, x => x.InstallDependenciesOnly(packageList.First()),
                settings.NoConfirm);
            if (!depsResult)
            {
                AnsiConsole.MarkupLine("[red]Installation failed. See errors above.[/]");
                return 1;
            }

            AnsiConsole.MarkupLine("[green]Packages installed successfully![/]");
            return 0;
        }

        if (settings.NoDeps)
        {
            AnsiConsole.MarkupLine("[yellow]Skipping dependency installation.[/]");
            AnsiConsole.MarkupLine("[yellow]Installing packages...[/]");
            var noDepsResult = await RunOutput(manager,
                x => x.InstallPackages(packageList, AlpmTransFlag.NoDeps),
                settings.NoConfirm);
            if (!noDepsResult)
            {
                AnsiConsole.MarkupLine("[red]Installation failed. See errors above.[/]");
                return 1;
            }

            AnsiConsole.MarkupLine("[green]Packages installed successfully![/]");
            return 0;
        }

        AnsiConsole.MarkupLine("[yellow]Installing packages...[/]");

        var installResult = await RunOutput(manager, x => x.InstallPackages(packageList), settings.NoConfirm);
        Console.WriteLine(); // Final newline after last package

        if (!installResult)
        {
            AnsiConsole.MarkupLine("[red]Installation failed. See errors above.[/]");
            return 1;
        }

        AnsiConsole.MarkupLine("[green]Packages installed successfully![/]");
        return 0;
    }

    private static async Task<int> HandleUiModeInstall(CommandContext context, InstallPackageSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, "No packages specified"));
            return 1;
        }

        if (settings.Upgrade)
        {
            var command = new UpgradeCommand();
            await command.ExecuteAsync(context, new UpgradeSettings { JsonOutput = true });
        }

        using var manager = new AlpmManager();
        manager.Initialize(true);
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, settings.NoConfirm);
  

        var packageList = settings.Packages.ToList();

        if (settings.BuildDepsOn)
        {
            if (settings.Packages.Length > 1)
            {
                JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(
                    EventLevel.Error, "Cannot build dependencies for multiple packages at once."));
                return 1;
            }

            var includeMake = settings.MakeDepsOn;
            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                AlpmEvents.TransactionStart,
                includeMake
                    ? "Installing dependencies (including make dependencies)..."
                    : "Installing dependencies..."));

            var depsOk = await UiModeOutput.Run(manager,
                m => m.InstallDependenciesOnly(packageList[0], includeMake));

            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                depsOk ? AlpmEvents.TransactionDone : AlpmEvents.TransactionFailed,
                depsOk ? "Dependencies installed successfully!" : "Dependency installation failed."));
            return depsOk ? 0 : 1;
        }

        var flags = settings.NoDeps ? AlpmTransFlag.NoDeps : AlpmTransFlag.None;
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            AlpmEvents.TransactionStart,
            $"Installing packages: {string.Join(", ", packageList)}"));

        var ok = await UiModeOutput.Run(manager, m => m.InstallPackages(packageList, flags));

        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            ok ? AlpmEvents.TransactionDone : AlpmEvents.TransactionFailed,
            ok ? "Packages installed successfully!" : "Installation failed."));
        return ok ? 0 : 1;
    }
}