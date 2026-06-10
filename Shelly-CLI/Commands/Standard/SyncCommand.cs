using System.Diagnostics.CodeAnalysis;
using PackageManager.Alpm;
using PackageManager.Wire;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Shelly.Utilities.Eventing;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class SyncCommand : Command<SyncSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] SyncSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiMode(settings);
        }

        RootElevator.EnsureRootExectuion();
        using var manager = new AlpmManager();
        object renderLock = new();

        AnsiConsole.Status()
            .Spinner(Spinner.Known.Dots)
            .Start("Initializing ALPM...", ctx => { manager.Initialize(true); });

        AnsiConsole.MarkupLine("[yellow]Synchronizing package databases...[/]");
        var progressTable = new Table().AddColumns("Package", "Progress", "Status", "Stage");
        AnsiConsole.Live(progressTable).AutoClear(false)
            .Start(ctx =>
            {
                var rowIndex = new Dictionary<string, int>();

                manager.Progress += (sender, args) =>
                {
                    lock (renderLock)
                    {
                        var name = args.PackageName ?? "unknown";
                        var pct = args.Percent ?? 0;
                        var bar = ProgressBarRenderer.RenderStatic(pct, 20);
                        var actionType = args.ProgressType;

                        if (!rowIndex.TryGetValue(name, out var idx))
                        {
                            progressTable.AddRow(
                                $"[blue]{Markup.Escape(name)}[/]",
                                $"[green]{bar}[/]",
                                $"{pct}%",
                                $"{actionType}"
                            );
                            rowIndex[name] = rowIndex.Count;
                        }
                        else
                        {
                            progressTable.UpdateCell(idx, 1, $"[green]{bar}[/]");
                            progressTable.UpdateCell(idx, 2, $"{pct}%");
                            progressTable.UpdateCell(idx, 3, $"{actionType}");
                        }

                        ctx.Refresh();
                    }
                };
                manager.Sync(settings.Force);
            });

        AnsiConsole.MarkupLine("[green]Package databases synchronized successfully![/]");
        return 0;
    }

    private static int HandleUiMode(SyncSettings settings)
    {
        using var manager = new AlpmManager();
        manager.Progress += (_, args) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmPackageProgressEvent(
                args.PackageName ?? "Unknown Package",
                args.Current ?? 0,
                args.HowMany ?? 0,
                args.ProgressType.ToProgressType(),
                args.Percent ?? 0,
                args.Message));
        };
        manager.ErrorEvent += (_, e) =>
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, e.Error));

        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            AlpmEvents.TransactionStart, "Synchronizing package databases..."));
        manager.Sync(settings.Force);
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            AlpmEvents.TransactionDone, "Package databases synchronized successfully"));
        return 0;
    }
}