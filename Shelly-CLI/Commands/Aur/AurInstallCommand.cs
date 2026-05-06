using System;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using System.Linq;
using PackageManager.Alpm;
using PackageManager.Aur;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
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

        AnsiConsole.MarkupLine($"[yellow]AUR packages to install:[/] {string.Join(", ", packageList.Select(p => p.EscapeMarkup()))}");

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

        Func<AurPackageManager, Func<AurPackageManager, Task>, bool, Task<bool>> runOutput =
            useSinglePane
                ? (m, op, nc) => AurSinglePaneOutput.Output(m, op, nc)
                : (m, op, nc) => AurSplitOutput.Output(m, op, nc);

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
                    var makeDepsResult = await runOutput(manager, m => m.InstallDependenciesOnly(packageList.First(), true), settings.NoConfirm);
                    if (!makeDepsResult)
                    {
                        AnsiConsole.MarkupLine("[red]Dependency installation failed. See errors above.[/]");
                        return 1;
                    }
                    AnsiConsole.MarkupLine("[green]Dependencies installed successfully![/]");
                    return 0;
                }

                AnsiConsole.MarkupLine("[yellow]Installing dependencies...[/]");
                var depsResult = await runOutput(manager, m => m.InstallDependenciesOnly(packageList.First(), false), settings.NoConfirm);
                if (!depsResult)
                {
                    AnsiConsole.MarkupLine("[red]Dependency installation failed. See errors above.[/]");
                    return 1;
                }
                AnsiConsole.MarkupLine("[green]Dependencies installed successfully![/]");
                return 0;
            }

            AnsiConsole.MarkupLine($"[yellow]Installing AUR packages: {string.Join(", ", settings.Packages.Select(p => p.EscapeMarkup()))}[/]");
            var installResult = await runOutput(manager, m => m.InstallPackages(packageList), settings.NoConfirm);
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
            Console.Error.WriteLine("Error: No packages specified");
            return 1;
        }

        AurPackageManager? manager = null;
        bool hadError = false;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true, useChroot: settings.UseChroot, noCheck: !settings.Check);

            var packageList = settings.Packages.ToList();

            // Handle package progress events
            manager.PackageProgress += (sender, args) =>
            {
                Console.Error.WriteLine($"[{args.CurrentIndex}/{args.TotalCount}] {args.PackageName}: {args.Status}" +
                                        (args.Message != null ? $" - {args.Message}" : ""));
            };

            // Handle progress events
            manager.Progress += (sender, args) => { Console.Error.WriteLine($"{args.PackageName}: {args.Percent}%"); };

            // Handle questions
            manager.Question += (sender, args) => { QuestionHandler.HandleQuestion(args, true, settings.NoConfirm); };

            // Handle build output
            manager.BuildOutput += (sender, e) =>
            {
                if (e.IsError)
                    Console.Error.WriteLine($"[Shelly] makepkg error: {e.Line}");
                else if (e.Percent.HasValue)
                    Console.Error.WriteLine($"[AUR_PROGRESS]Percent: {e.Percent}% Message: {e.ProgressMessage}");
                else
                    Console.Error.WriteLine($"[Shelly] makepkg: {e.Line}");
            };

            manager.ErrorEvent += (_, e) =>
            {
                Console.Error.WriteLine($"[ALPM_ERROR]{e.Error}");
                hadError = true;
            };

            // Handle build dependencies only mode
            if (settings.BuildDepsOn)
            {
                if (settings.Packages.Length > 1)
                {
                    Console.Error.WriteLine("Cannot build dependencies for multiple packages at once.");
                    return 1;
                }

                if (settings.MakeDepsOn)
                {
                    Console.Error.WriteLine("Installing dependencies (including make dependencies)...");
                    await manager.InstallDependenciesOnly(packageList.First(), true);
                    if (hadError) return 1;
                    Console.Error.WriteLine("Dependencies installed successfully!");
                    return 0;
                }

                Console.Error.WriteLine("Installing dependencies...");
                await manager.InstallDependenciesOnly(packageList.First(), false);
                if (hadError) return 1;
                Console.Error.WriteLine("Dependencies installed successfully!");
                return 0;
            }

            Console.Error.WriteLine($"Installing AUR packages: {string.Join(", ", packageList)}");
            await manager.InstallPackages(packageList);
            if (hadError) return 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Installation failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
        
        Console.Error.WriteLine("Installation complete.");

        return 0;
    }
    
    private static async Task<List<string>> GetMissingPackages(AurPackageManager manager, List<string> packageList)
    {
        var installedPackages = await manager.GetInstalledPackages();
        var installedPackageNames = installedPackages
            .Select(package => package.Name)
            .ToHashSet(StringComparer.Ordinal);

        return packageList
            .Where(packageName => !installedPackageNames.Contains(packageName))
            .ToList();
    }
}