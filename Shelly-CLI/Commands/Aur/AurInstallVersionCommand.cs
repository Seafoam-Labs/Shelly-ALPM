using System.Diagnostics.CodeAnalysis;
using PackageManager.Alpm;
using PackageManager.Aur;
using PackageManager.Wire;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Shelly.Utilities.Eventing;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Aur;

public class AurInstallVersionCommand : AsyncCommand<AurInstallVersionSettings>
{
    public override async Task<int> ExecuteAsync([NotNull] CommandContext context,
        [NotNull] AurInstallVersionSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeInstallVersion(settings);
        }

        RootElevator.EnsureRootExectuion();
        AurPackageManager? manager = null;
        if (string.IsNullOrWhiteSpace(settings.Package))
        {
            AnsiConsole.MarkupLine("[red]No package specified.[/]");
            return 1;
        }

        if (string.IsNullOrWhiteSpace(settings.Commit))
        {
            AnsiConsole.MarkupLine("[red]No commit specified.[/]");
            return 1;
        }

        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true, noCheck: !settings.Check);

            manager.InformationalEvent += (_, args) =>
            {
                var statusColor = args.EventType switch
                {
                    AlpmEventType.AurDownloadStart => "yellow",
                    AlpmEventType.AurBuildStart => "blue",
                    AlpmEventType.AurInstallStart => "cyan",
                    AlpmEventType.AurPackageCompleted => "green",
                    AlpmEventType.AurPackageFailed => "red",
                    _ => null
                };
                if (statusColor == null) return;

                AnsiConsole.MarkupLine(
                    $"[{statusColor}][[{args.CurrentIndex}/{args.TotalCount}]] {(args.PackageName ?? "").EscapeMarkup()}: {args.EventType}[/]" +
                    (!string.IsNullOrEmpty(args.Message) ? $" - {args.Message.EscapeMarkup()}" : ""));
            };

            AnsiConsole.MarkupLine(
                $"[yellow]Installing AUR package {settings.Package.EscapeMarkup()} at commit {settings.Commit.EscapeMarkup()}[/]");
            await manager.InstallPackageVersion(settings.Package, settings.Commit);
            AnsiConsole.MarkupLine("[green]Installation complete.[/]");

            return 0;
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
    }

    private static async Task<int> HandleUiModeInstallVersion(AurInstallVersionSettings settings)
    {
        AurPackageManager? manager = null;
        if (string.IsNullOrWhiteSpace(settings.Package))
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, "No package specified"));
            return 1;
        }

        if (string.IsNullOrWhiteSpace(settings.Commit))
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, "No commit specified"));
            return 1;
        }

        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true, noCheck: !settings.Check);
            // Handle questions
            manager.Question += (sender, args) => { QuestionHandler.HandleQuestion(args, true, false); };

            manager.PkgbuildDiffRequest += (_, args) =>
                QuestionHandler.HandleQuestion(args, Program.IsUiMode, false);

            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(AlpmEvents.InformationalOutput,
                $"Installing AUR package {settings.Package} at commit {settings.Commit}"));
            var ok =
                await UiModeOutput.Run(manager, m => m.InstallPackageVersion(settings.Package, settings.Commit));
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