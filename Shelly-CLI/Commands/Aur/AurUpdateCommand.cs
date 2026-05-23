using System.Diagnostics.CodeAnalysis;
using PackageManager.Alpm;
using PackageManager.Aur;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Aur;

public class AurUpdateCommand : AsyncCommand<AurPackageSettings>
{
    public override async Task<int> ExecuteAsync([NotNull] CommandContext context,
        [NotNull] AurPackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeUpdate(settings);
        }

        if (settings.Packages.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]No packages specified.[/]");
            return 1;
        }


        RootElevator.EnsureRootExectuion();
        
        if (!settings.NoConfirm)
        {
            if (!AnsiConsole.Confirm($"[yellow]Proceed with update for {string.Join(",", settings.Packages)} ?[/]",
                    defaultValue: true))
            {
                AnsiConsole.MarkupLine("[yellow]Upgrade cancelled.[/]");
                return 0;
            }
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(true, noCheck: !settings.Check);
            var cfg = ConfigManager.ReadConfig();
            var useSinglePane = settings.SinglePane ||
                                string.Equals(cfg.OutputMode, "singlepane", StringComparison.OrdinalIgnoreCase) ||
                                Console.IsOutputRedirected;
            var result = useSinglePane
                ? await AurSinglePaneOutput.Output(manager, m => m.UpdatePackages(settings.Packages.ToList()),
                    settings.NoConfirm)
                : await AurSplitOutput.Output(manager, m => m.UpdatePackages(settings.Packages.ToList()),
                    settings.NoConfirm);
            if (!result)
            {
                AnsiConsole.MarkupLine("[red]Update failed. See errors above.[/]");
                return 1;
            }

            AnsiConsole.MarkupLine("[green]Update complete.[/]");
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Update failed:[/] {ex.Message.EscapeMarkup()}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }

        return 0;
    }

    private static async Task<int> HandleUiModeUpdate(AurPackageSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            Console.Error.WriteLine("No packages specified.");
            return 1;
        }

        AurPackageManager? manager = null;
        bool hadError = false;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true, noCheck: !settings.Check);

            manager.HookRun += (_, args) => Console.Error.WriteLine($"[ALPM_HOOK]{args.Description}");
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

            manager.Progress += (sender, args) => { Console.Error.WriteLine($"{args.PackageName}: {args.Percent}%"); };

            manager.Question += (sender, args) => { QuestionHandler.HandleQuestion(args, true, settings.NoConfirm); };

            manager.BuildOutput += (sender, e) =>
            {
                if (e.IsError)
                    Console.Error.WriteLine($"[Shelly] makepkg error: {e.Line}");
                else if (e.Percent.HasValue)
                    Console.Error.WriteLine($"[AUR_PROGRESS]Percent: {e.Percent}% Message: {e.ProgressMessage}");
                else
                    Console.Error.WriteLine($"[Shelly] makepkg: {e.Line}");
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

            Console.Error.WriteLine($"Updating AUR packages: {string.Join(", ", settings.Packages)}");
            await manager.UpdatePackages(settings.Packages.ToList());
            if (hadError)
            {
                Console.Error.WriteLine("Update failed.");
                return 1;
            }

            Console.Error.WriteLine("Update complete.");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Update failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }

        return 0;
    }
}