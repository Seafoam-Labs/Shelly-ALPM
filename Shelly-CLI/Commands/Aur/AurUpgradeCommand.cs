using System.Diagnostics.CodeAnalysis;
using PackageManager.Aur;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Aur;

public class AurUpgradeCommand : AsyncCommand<AurUpgradeSettings>
{
    public override async Task<int> ExecuteAsync([NotNull] CommandContext context,
        [NotNull] AurUpgradeSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeUpgrade(settings);
        }

        AurPackageManager? manager = null;
        try
        {
            RootElevator.EnsureRootExectuion();
            manager = new AurPackageManager();
            await manager.Initialize(root: true, noCheck: !settings.Check);

            var updates = await manager.GetPackagesNeedingUpdate();

            if (updates.Count == 0)
            {
                AnsiConsole.MarkupLine("[green]All AUR packages are up to date.[/]");
                return 0;
            }

            AnsiConsole.MarkupLine($"[yellow]{updates.Count} AUR packages need updates:[/]");
            foreach (var pkg in updates)
            {
                AnsiConsole.MarkupLine(
                    $"  {pkg.Name.EscapeMarkup()}: {pkg.Version.EscapeMarkup()} -> {pkg.NewVersion.EscapeMarkup()}");
            }

            if (!settings.NoConfirm)
            {
                if (!AnsiConsole.Confirm("[yellow]Proceed with upgrade?[/]", defaultValue: true))
                {
                    AnsiConsole.MarkupLine("[yellow]Upgrade cancelled.[/]");
                    return 0;
                }
            }

            var cfg = ConfigManager.ReadConfig();
            var useSinglePane = settings.SinglePane
                                || string.Equals(cfg.OutputMode, "singlepane", StringComparison.OrdinalIgnoreCase)
                                || Console.IsOutputRedirected;

            var packageNames = updates.Select(u => u.Name).ToList();
            var result = useSinglePane
                ? await AurSinglePaneOutput.Output(manager, m => m.UpdatePackages(packageNames), settings.NoConfirm)
                : await AurSplitOutput.Output(manager, m => m.UpdatePackages(packageNames), settings.NoConfirm);
            if (!result)
            {
                AnsiConsole.MarkupLine("[red]Upgrade failed. See errors above.[/]");
                return 1;
            }

            AnsiConsole.MarkupLine("[green]Upgrade complete.[/]");
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Upgrade failed:[/] {ex.Message.EscapeMarkup()}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }

        return 0;
    }

    private static async Task<int> HandleUiModeUpgrade(AurUpgradeSettings settings)
    {
        AurPackageManager? manager = null;
        bool hadError = false;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true, noCheck: !settings.Check);

            var updates = await manager.GetPackagesNeedingUpdate();

            if (updates.Count == 0)
            {
                Console.Error.WriteLine("All AUR packages are up to date.");
                return 0;
            }

            Console.Error.WriteLine($"{updates.Count} AUR packages need updates:");
            foreach (var pkg in updates)
            {
                Console.Error.WriteLine($"  {pkg.Name}: {pkg.Version} -> {pkg.NewVersion}");
            }

            manager.ErrorEvent += (_, e) =>
            {
                Console.Error.WriteLine($"[ALPM_ERROR]{e.Error}");
                hadError = true;
            };

            manager.Replaces += (_, args) =>
            {
                foreach (var replace in args.Replaces)
                {
                    Console.Error.WriteLine(
                        $"Replacement: {args.Repository}/{args.PackageName} replaces {replace}");
                }
            };

            manager.Question += (_, args) =>
            {
                Console.Error.WriteLine();
                QuestionHandler.HandleQuestion(args, Program.IsUiMode, settings.NoConfirm);
            };

            manager.Progress += (_, args) =>
            {
                var name = args.PackageName ?? "unknown";
                var pct = args.Percent ?? 0;
                var actionType = args.ProgressType;
                Console.Error.WriteLine($"{name}: {pct}% - {actionType}");
            };

            manager.HookRun += (_, args) => Console.Error.WriteLine($"[ALPM_HOOK]{args.Description}");

            manager.ScriptletInfo += (_, args) => Console.Error.WriteLine($"[Shelly][ALPM_SCRIPTLET]{args.Line}");

            manager.PackageProgress += (sender, args) =>
            {
                Console.Error.WriteLine($"[{args.CurrentIndex}/{args.TotalCount}] {args.PackageName}: {args.Status}" +
                                        (args.Message != null ? $" - {args.Message}" : ""));
            };

            manager.BuildOutput += (sender, e) =>
            {
                if (e.IsError)
                {
                    Console.Error.WriteLine($"[Shelly] makepkg error: {e.Line}");
                }
                else if (e.Percent.HasValue)
                {
                    Console.Error.WriteLine($"[AUR_PROGRESS]Percent: {e.Percent}% Message: {e.ProgressMessage}");
                }
                else
                {
                    Console.Error.WriteLine($"[Shelly] makepkg: {e.Line}");
                }
            };

            manager.PkgbuildDiffRequest += (sender, args) =>
            {
                if (settings.NoConfirm)
                {
                    args.ProceedWithUpdate = true;
                    return;
                }

                PackageBuilderDiffGenerator.PrintUnifiedDiff(args.OldPkgbuild, args.NewPkgbuild, Program.IsUiMode);
                args.ProceedWithUpdate = true;
            };

            var packageNames = updates.Select(u => u.Name).ToList();
            await manager.UpdatePackages(packageNames);
            if (hadError)
            {
                await Console.Error.WriteLineAsync("Upgrade failed.");
                return 1;
            }

            await Console.Error.WriteLineAsync("Upgrade complete.");
        }
        catch (Exception ex)
        {
            await  Console.Error.WriteLineAsync($"Upgrade failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }

        return 0;
    }
    
}