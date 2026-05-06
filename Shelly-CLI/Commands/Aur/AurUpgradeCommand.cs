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
                AnsiConsole.MarkupLine($"  {pkg.Name.EscapeMarkup()}: {pkg.Version.EscapeMarkup()} -> {pkg.NewVersion.EscapeMarkup()}");
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

                Console.Error.WriteLine($"PKGBUILD changed for {args.PackageName}.");
                Console.Error.WriteLine("--- Old PKGBUILD ---");
                Console.Error.WriteLine(args.OldPkgbuild);
                Console.Error.WriteLine("--- New PKGBUILD ---");
                Console.Error.WriteLine(args.NewPkgbuild);
                args.ProceedWithUpdate = true;
            };

            var packageNames = updates.Select(u => u.Name).ToList();
            await manager.UpdatePackages(packageNames);
            if (hadError)
            {
                Console.Error.WriteLine("Upgrade failed.");
                return 1;
            }
            Console.Error.WriteLine("Upgrade complete.");

         
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Upgrade failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
        return 0;
    }
    
    private static void PrintUnifiedDiff(string oldText, string newText)
    {
        var oldLines = oldText.Split('\n');
        var newLines = newText.Split('\n');

        // Build LCS table
        var lcs = new int[oldLines.Length + 1, newLines.Length + 1];
        for (int i = oldLines.Length - 1; i >= 0; i--)
        for (int j = newLines.Length - 1; j >= 0; j--)
            lcs[i, j] = oldLines[i].TrimEnd('\r') == newLines[j].TrimEnd('\r')
                ? lcs[i + 1, j + 1] + 1
                : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);

        // Walk the table to produce diff output
        int oi = 0, ni = 0;
        while (oi < oldLines.Length || ni < newLines.Length)
        {
            if (oi < oldLines.Length && ni < newLines.Length &&
                oldLines[oi].TrimEnd('\r') == newLines[ni].TrimEnd('\r'))
            {
                AnsiConsole.MarkupLine($"[white]  {oldLines[oi].TrimEnd('\r').EscapeMarkup()}[/]");
                oi++; ni++;
            }
            else if (ni < newLines.Length &&
                     (oi >= oldLines.Length || lcs[oi, ni + 1] >= lcs[oi + 1, ni]))
            {
                AnsiConsole.MarkupLine($"[green]+ {newLines[ni].TrimEnd('\r').EscapeMarkup()}[/]");
                ni++;
            }
            else
            {
                AnsiConsole.MarkupLine($"[red]- {oldLines[oi].TrimEnd('\r').EscapeMarkup()}[/]");
                oi++;
            }
        }
    }
}