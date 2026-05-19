using System;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using System.Linq;
using PackageManager.Alpm;
using PackageManager.Aur;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Aur;

public class AurRemoveCommand : AsyncCommand<AurRemovePackageSettings>
{
    public override async Task<int> ExecuteAsync([NotNull] CommandContext context,
        [NotNull] AurRemovePackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeRemove(settings);
        }

        AurPackageManager? manager = null;
        if (settings.Packages.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]No packages specified.[/]");
            return 1;
        }

        try
        {
            RootElevator.EnsureRootExectuion();
            manager = new AurPackageManager();
            await manager.Initialize(root: true);
            object renderLock = new();
            bool hadError = false;

            manager.PackageProgress += (sender, args) =>
            {
                lock (renderLock)
                {
                    var statusColor = args.Status switch
                    {
                        PackageProgressStatus.Downloading => "yellow",
                        PackageProgressStatus.Building => "blue",
                        PackageProgressStatus.Installing => "cyan",
                        PackageProgressStatus.Completed => "green",
                        PackageProgressStatus.Failed => "red",
                        _ => "white"
                    };

                    AnsiConsole.MarkupLine(
                        $"[{statusColor}][[{args.CurrentIndex}/{args.TotalCount}]] {args.PackageName.EscapeMarkup()}: {args.Status}[/]" +
                        (args.Message != null ? $" - {args.Message.EscapeMarkup()}" : ""));
                }
            };

            manager.Question += (sender, args) =>
            {
                lock (renderLock)
                {
                    AnsiConsole.WriteLine();
                    // Handle SelectProvider and ConflictPkg differently - they need a selection, not yes/no
                    QuestionHandler.HandleQuestion(args, Program.IsUiMode, settings.NoConfirm);
                }
            };

            manager.ErrorEvent += (_, e) =>
            {
                lock (renderLock)
                {
                    AnsiConsole.MarkupLine($"[red]ERROR: {e.Error.EscapeMarkup()}[/]");
                }
                hadError = true;
            };

            var flags = AlpmTransFlag.None;
            if (settings.Cascade)
            {
                flags |= AlpmTransFlag.NoSave|AlpmTransFlag.Recurse;

            }
            else if(settings.Ripple)
            {
                flags |= AlpmTransFlag.Cascade;
            }

            AnsiConsole.MarkupLine($"[yellow]Removing AUR packages: {string.Join(", ", settings.Packages.Select(p => p.EscapeMarkup()))}[/]");
            var progressTable = new Table().AddColumns("Package", "Progress", "Status", "Stage");
            await AnsiConsole.Live(progressTable).AutoClear(false)
                .StartAsync(async ctx =>
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
                    await manager.RemovePackages(settings.Packages.ToList(), flags, settings.OptDeps);
                });

            if (hadError)
            {
                AnsiConsole.MarkupLine("[red]Removal failed. See errors above.[/]");
                return 1;
            }
            AnsiConsole.MarkupLine("[green]Removal complete.[/]");

            return 0;
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Removal failed:[/] {ex.Message.EscapeMarkup()}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    private static async Task<int> HandleUiModeRemove(AurRemovePackageSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            Console.Error.WriteLine("Error: No packages specified");
            return 1;
        }
        var flags = AlpmTransFlag.None;
        if (settings.Cascade)
        {
            flags |= AlpmTransFlag.NoSave|AlpmTransFlag.Recurse;

        }
        else if(settings.Ripple)
        {
            flags |= AlpmTransFlag.Cascade;
        }

        AurPackageManager? manager = null;
        bool hadError = false;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true);

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

            manager.ErrorEvent += (_, e) =>
            {
                Console.Error.WriteLine($"[ALPM_ERROR]{e.Error}");
                hadError = true;
            };

            Console.Error.WriteLine($"Removing AUR packages: {string.Join(", ", packageList)}");
            await manager.RemovePackages(packageList, flags, settings.OptDeps);
            if (hadError)
            {
                Console.Error.WriteLine("Removal failed.");
                return 1;
            }
            Console.Error.WriteLine("Removal complete.");

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Removal failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}