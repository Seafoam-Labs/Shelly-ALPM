using System;
using System.Diagnostics.CodeAnalysis;
using System.Linq;
using PackageManager.Alpm;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class InstallCommand : Command<InstallPackageSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] InstallPackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeInstall(context,settings);
        }

        if (settings.Packages.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]Error: No packages specified[/]");
            return 1;
        }

        RootElevator.EnsureRootExectuion();

        var packageList = settings.Packages.ToList();

        AnsiConsole.MarkupLine($"[yellow]Packages to install:[/] {string.Join(", ", packageList)}");

        if (!AnsiConsole.Confirm("Do you want to proceed?"))
        {
            AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
            return 0;
        }


        using var manager = new AlpmManager();
        object renderLock = new();

        manager.Question += (sender, args) =>
        {
            lock (renderLock)
            {
                AnsiConsole.WriteLine();
                QuestionHandler.HandleQuestion(args, Program.IsUiMode, settings.NoConfirm);
            }
        };

        AnsiConsole.MarkupLine("[yellow]Initializing and syncing ALPM...[/]");
        manager.Initialize(true);
        if (settings.Upgrade)
        {
            AnsiConsole.Markup("[yellow]Running system upgrade[/yellow]");
            manager.SyncSystemUpdate();
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
                manager.InstallDependenciesOnly(packageList.First(), true, AlpmTransFlag.None);
                return 0;
            }

            AnsiConsole.MarkupLine("[yellow]Installing packages...[/]");
            manager.InstallDependenciesOnly(packageList.First(), false, AlpmTransFlag.None);
            AnsiConsole.MarkupLine("[green]Packages installed successfully![/]");
            return 0;
        }

        if (settings.NoDeps)
        {
            AnsiConsole.MarkupLine("[yellow]Skipping dependency installation.[/]");
            AnsiConsole.MarkupLine("[yellow]Installing packages...[/]");
            manager.InstallPackages(packageList, AlpmTransFlag.NoDeps);
            AnsiConsole.MarkupLine("[green]Packages installed successfully![/]");
            return 0;
        }

        AnsiConsole.MarkupLine("[yellow]Installing packages...[/]");

        int currentPkgIndex = 0;
        int totalPkgs = packageList.Count;
        string? lastPackageName = null;
        int lastPercent = 0;

        manager.Progress += (sender, args) =>
        {
            lock (renderLock)
            {
                var name = args.PackageName ?? "unknown";
                var pct = args.Percent ?? 0;
                var bar = new string('█', pct / 5) + new string('░', 20 - pct / 5);
                var actionType = args.ProgressType;

                // Detect package change
                if (name != lastPackageName)
                {
                    // If this isn't the first package, complete the previous line
                    if (lastPackageName != null)
                    {
                        Console.WriteLine(); // Move to new line
                        currentPkgIndex++;
                    }

                    lastPackageName = name;
                    lastPercent = 0;
                }

                // Update current line with carriage return
                Console.Write(
                    $"\r({currentPkgIndex + 1}/{totalPkgs}) installing {name,-40}  [{bar}] {pct,3}% - {actionType,-20}");

                lastPercent = pct;
            }
        };
        
        manager.ScriptletInfo += (sender, args) =>
        {
            Console.WriteLine(args.Line);
        };

        manager.HookRun += (sender, args) =>
        {
            Console.WriteLine(args.Description);
        };

        manager.InstallPackages(packageList);
        Console.WriteLine(); // Final newline after last package

        AnsiConsole.MarkupLine("[green]Packages installed successfully![/]");
        return 0;
    }

    private static int HandleUiModeInstall(CommandContext context, InstallPackageSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            Console.Error.WriteLine("Error: No packages specified");
            return 1;
        }

        if (settings.Upgrade)
        {
            var command = new UpgradeCommand();
            command.ExecuteAsync(context, new UpgradeSettings()
            {
                JsonOutput = true,
            }).Wait();
        }

        using var manager = new AlpmManager();
        manager.Question += (sender, args) => { QuestionHandler.HandleQuestion(args, true, settings.NoConfirm); };
        Console.Error.WriteLine("Initializing ALPM...");
        manager.Initialize(true);

        if (settings.BuildDepsOn)
        {
            if (settings.Packages.Length > 1)
            {
                Console.WriteLine("Cannot build dependencies for multiple packages at once.");
                return -1;
            }

            if (settings.MakeDepsOn)
            {
                Console.Error.WriteLine("Installing packages...");
                manager.InstallDependenciesOnly(settings.Packages.ToList().First(), true, AlpmTransFlag.None);
                return 0;
            }

            Console.Error.WriteLine("Installing packages...");
            manager.InstallDependenciesOnly(settings.Packages.ToList().First(), false, AlpmTransFlag.None);
            Console.Error.WriteLine("Packages installed successfully!");
            return 0;
        }

        if (settings.NoDeps)
        {
            Console.Error.WriteLine("Skipping dependency installation.");
            Console.Error.WriteLine("Installing packages...");
            manager.InstallPackages(settings.Packages.ToList(), AlpmTransFlag.NoDeps);
            Console.Error.WriteLine("Packages installed successfully!");
            return 0;
        }

        Console.WriteLine("Installing packages...");
        var rowIndex = new Dictionary<string, int>();
        manager.Progress += (sender, args) => { Console.WriteLine($"{args.PackageName}: {args.Percent}%"); };
        manager.HookRun += (sender, args) =>
        {
            Console.Error.WriteLine($"[ALPM_HOOK]{args.Description}");
        };
        try
        {
            manager.InstallPackages(settings.Packages.ToList());
            Console.Error.WriteLine("Finished installing packages.");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ALPM_ERROR]Failed to install packages: {ex.Message}");
            return 1;
        }
        
        return 0;
    }
}