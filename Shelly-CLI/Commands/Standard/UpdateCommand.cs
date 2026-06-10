using System.Diagnostics.CodeAnalysis;
using PackageManager.Alpm;
using PackageManager.Wire;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Shelly.Utilities.Eventing;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class UpdateCommand : AsyncCommand<PackageSettings>
{
    public override async Task<int> ExecuteAsync([NotNull] CommandContext context, [NotNull] PackageSettings settings)
    {
        if (Program.IsUiMode)
            return await HandleUiModeUpdate(settings);

        if (settings.Packages.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]Error: No packages specified[/]");
            return 1;
        }

        RootElevator.EnsureRootExectuion();
        var packageList = settings.Packages.ToList();

        AnsiConsole.MarkupLine(
            $"[yellow]Packages to update:[/] {string.Join(", ", packageList.Select(p => p.EscapeMarkup()))}");

        if (!settings.NoConfirm)
        {
            if (!AnsiConsole.Confirm("Do you want to proceed?"))
            {
                AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
                return 0;
            }
        }

        using var manager = new AlpmManager();
        object renderLock = new();
        var hadError = false;

        manager.ErrorEvent += (_, e) =>
        {
            AnsiConsole.MarkupLine($"[red]ERROR: {e.Error.EscapeMarkup()}[/]");
            hadError = true;
        };

        manager.Question += (_, args) =>
        {
            lock (renderLock)
            {
                AnsiConsole.WriteLine();
                QuestionHandler.HandleQuestion(args, false, settings.NoConfirm);
            }
        };

        AnsiConsole.MarkupLine("[yellow]Initializing and syncing ALPM...[/]");
        manager.IntializeWithSync();

        AnsiConsole.MarkupLine("[yellow]Updating packages...[/]");
        var progressTable = new Table().AddColumns("Package", "Progress", "Status", "Stage");
        AnsiConsole.Live(progressTable).AutoClear(false)
            .Start(ctx =>
            {
                var rowIndex = new Dictionary<string, int>();

                manager.Progress += (_, args) =>
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
                manager.UpdatePackages(packageList);
            });

        if (hadError)
        {
            AnsiConsole.MarkupLine("[red]Update failed. See errors above.[/]");
            return 1;
        }

        AnsiConsole.MarkupLine("[green]Packages updated successfully![/]");
        return 0;
    }

    private static async Task<int> HandleUiModeUpdate(PackageSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, "No packages specified"));
            return 1;
        }

        using var manager = new AlpmManager();
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, settings.NoConfirm);
        manager.IntializeWithSync();

        var packageList = settings.Packages.ToList();
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            AlpmEvents.TransactionStart,
            $"Updating packages: {string.Join(", ", packageList)}"));

        var ok = await UiModeOutput.Run(manager, m => m.UpdatePackages(packageList));

        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            ok ? AlpmEvents.TransactionDone : AlpmEvents.TransactionFailed,
            ok ? "Packages updated successfully!" : "Update failed."));
        return ok ? 0 : 1;
    }
}
