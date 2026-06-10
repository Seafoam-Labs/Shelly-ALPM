using System;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using System.Linq;
using PackageManager.Alpm;
using PackageManager.Aur;
using PackageManager.Wire;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Shelly.Utilities.Eventing;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Aur;

public class AurInstallCommand : AsyncCommand<AurInstallSettings>
{
    public override async Task<int> ExecuteAsync([NotNull] CommandContext context,
        [NotNull] AurInstallSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeInstall(settings);
        }

        AurPackageManager? manager = null;
        if (settings.Packages.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]No packages specified.[/]");
            return 1;
        }

        RootElevator.EnsureRootExectuion();
        var packageList = settings.Packages.ToList();

        AnsiConsole.MarkupLine(
            $"[yellow]AUR packages to install:[/] {string.Join(", ", packageList.Select(p => p.EscapeMarkup()))}");

        if (!settings.NoConfirm)
        {
            if (!AnsiConsole.Confirm("Do you want to proceed?"))
            {
                AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
                return 0;
            }
        }

        var cfg = ConfigManager.ReadConfig();
        var useSinglePane = settings.SinglePane
                            || string.Equals(cfg.OutputMode, "singlepane", StringComparison.OrdinalIgnoreCase)
                            || Console.IsOutputRedirected;

        Task<bool> RunOutput(AurPackageManager m, Func<AurPackageManager, Task> op, bool nc) =>
            AurSinglePaneOutput.Output(m, op, nc);


        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true, useChroot: settings.UseChroot, noCheck: !settings.Check);

            if (settings.BuildDepsOn)
            {
                if (settings.Packages.Length > 1)
                {
                    AnsiConsole.MarkupLine("[yellow]Cannot build dependencies for multiple packages at once.[/]");
                    return 0;
                }

                if (settings.MakeDepsOn)
                {
                    AnsiConsole.MarkupLine("[yellow]Installing dependencies (including make dependencies)...[/]");
                    var makeDepsResult = await RunOutput(manager,
                        m => m.InstallDependenciesOnly(packageList.First(), true), settings.NoConfirm);
                    if (!makeDepsResult)
                    {
                        AnsiConsole.MarkupLine("[red]Dependency installation failed. See errors above.[/]");
                        return 1;
                    }

                    AnsiConsole.MarkupLine("[green]Dependencies installed successfully![/]");
                    return 0;
                }

                AnsiConsole.MarkupLine("[yellow]Installing dependencies...[/]");
                var depsResult = await RunOutput(manager, m => m.InstallDependenciesOnly(packageList.First(), false),
                    settings.NoConfirm);
                if (!depsResult)
                {
                    AnsiConsole.MarkupLine("[red]Dependency installation failed. See errors above.[/]");
                    return 1;
                }

                AnsiConsole.MarkupLine("[green]Dependencies installed successfully![/]");
                return 0;
            }

            AnsiConsole.MarkupLine(
                $"[yellow]Installing AUR packages: {string.Join(", ", settings.Packages.Select(p => p.EscapeMarkup()))}[/]");
            var installResult = await RunOutput(manager, m => m.InstallPackages(packageList), settings.NoConfirm);
            if (!installResult)
            {
                AnsiConsole.MarkupLine("[red]Installation failed. See errors above.[/]");
                return 1;
            }
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Installation failed:[/] {ex.Message.EscapeMarkup()}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }

        AnsiConsole.MarkupLine("[green]Installation complete.[/]");

        return 0;
    }

    private static async Task<int> HandleUiModeInstall(AurInstallSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, "No packages specified"));
            return 1;
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true, useChroot: settings.UseChroot, noCheck: !settings.Check);

            // Handle questions
            manager.Question += (sender, args) => { QuestionHandler.HandleQuestion(args, true, settings.NoConfirm); };

            manager.PkgbuildDiffRequest += (_, args) =>
                QuestionHandler.HandleQuestion(args, Program.IsUiMode, settings.NoConfirm);

            var packageList = settings.Packages.ToList();


            // Handle build dependencies only mode
            if (settings.BuildDepsOn)
            {
                if (settings.Packages.Length > 1)
                {
                    JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error,
                        "Cannot build dependencies for multiple packages at once."));
                    return 1;
                }

                var includeMake = settings.MakeDepsOn;
                JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(AlpmEvents.InformationalOutput,
                    "Installing dependencies (including make dependencies)..."));
                var depsResult = await UiModeOutput.Run(manager,
                    m => m.InstallDependenciesOnly(packageList.First(), includeMake));
                if (!depsResult) return 1;
                JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(AlpmEvents.InformationalOutput,
                    "Dependencies installed successfully!"));
                return 0;
            }

            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                AlpmEvents.AurDownloadStart,
                $"Installing AUR packages: {string.Join(", ", packageList)}"));
            
            var ok = await UiModeOutput.Run(manager, m => m.InstallPackages(packageList));
            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                ok ? AlpmEvents.AurPackageCompleted : AlpmEvents.AurPackageFailed,
                ok ? "Installation complete." : "Installation failed."));
            return ok ? 0 : 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}