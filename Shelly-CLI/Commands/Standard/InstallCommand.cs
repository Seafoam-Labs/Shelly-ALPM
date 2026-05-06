using PackageManager.Alpm;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
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

        var cfg = ConfigManager.ReadConfig();
        var useSinglePane = settings.SinglePane
            || string.Equals(cfg.OutputMode, "singlepane", StringComparison.OrdinalIgnoreCase)
            || Console.IsOutputRedirected;
        Func<IAlpmManager, Func<IAlpmManager, Task<bool>>, bool, Task<bool>> runOutput =
            useSinglePane
                ? (m, op, nc) => StandardSinglePaneOutput.Output(m, op, nc)
                : (m, op, nc) => SplitOutput.Output(m, op, nc);

        if (settings.Upgrade)
        {
            AnsiConsole.Markup("[yellow]Running system upgrade[/yellow]");
            var upgradeResult = await runOutput(manager, x => x.SyncSystemUpdate(), settings.NoConfirm);
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
                var result = await runOutput(manager,
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
            var depsResult = await runOutput(manager, x => x.InstallDependenciesOnly(packageList.First()),
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
            var noDepsResult = await runOutput(manager,
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

        var installResult = await runOutput(manager, x => x.InstallPackages(packageList), settings.NoConfirm);
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
        bool hadError = false;
        manager.Question += (_, args) => { QuestionHandler.HandleQuestion(args, true, settings.NoConfirm); };
        manager.Progress += (_, args) => { Console.WriteLine($"{args.PackageName}: {args.Percent}%"); };
        manager.HookRun += (_, args) => { Console.Error.WriteLine($"[ALPM_HOOK]{args.Description}"); };
        manager.ErrorEvent += (_, e) =>
        {
            Console.Error.WriteLine($"[ALPM_ERROR]{e.Error}");
            hadError = true;
        };
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
                var result = await manager.InstallDependenciesOnly(settings.Packages.ToList().First(), true);
                if (!result || hadError) return 1;
                return 0;
            }

            Console.Error.WriteLine("Installing packages...");
            var depsResult = await manager.InstallDependenciesOnly(settings.Packages.ToList().First());
            if (!depsResult || hadError) return 1;
            Console.Error.WriteLine("Packages installed successfully!");
            return 0;
        }

        if (settings.NoDeps)
        {
            Console.Error.WriteLine("Skipping dependency installation.");
            Console.Error.WriteLine("Installing packages...");
            var noDepsResult = await manager.InstallPackages(settings.Packages.ToList(), AlpmTransFlag.NoDeps);
            if (!noDepsResult || hadError) return 1;
            Console.Error.WriteLine("Packages installed successfully!");
            return 0;
        }

        Console.WriteLine("Installing packages...");
        var installResult = await manager.InstallPackages(settings.Packages.ToList());
        if (!installResult || hadError) return 1;
        Console.Error.WriteLine("Finished installing packages.");
        return 0;
    }
}