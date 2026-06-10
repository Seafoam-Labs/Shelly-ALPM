using System.Diagnostics.CodeAnalysis;
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
            var result = await AurSinglePaneOutput.Output(manager, m => m.UpdatePackages(settings.Packages.ToList()),
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
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, "No packages specified"));
            return 1;
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true, noCheck: !settings.Check);

            manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, settings.NoConfirm);
            manager.PkgbuildDiffRequest += (_, args) =>
                QuestionHandler.HandleQuestion(args, Program.IsUiMode, settings.NoConfirm);

            var packageList = settings.Packages.ToList();
            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                AlpmEvents.AurDownloadStart,
                $"Updating AUR packages: {string.Join(", ", packageList)}"));

            var ok = await UiModeOutput.Run(manager, m => m.UpdatePackages(packageList));

            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                ok ? AlpmEvents.AurPackageCompleted : AlpmEvents.AurPackageFailed,
                ok ? "Update complete." : "Update failed."));
            return ok ? 0 : 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}