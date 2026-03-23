using System.Diagnostics.CodeAnalysis;
using PackageManager.Alpm;
using Shelly_CLI.Commands.Aur;
using Shelly_CLI.Commands.Flatpak;
using Shelly_CLI.Configuration;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class UpgradeCommand : Command<UpgradeSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] UpgradeSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeUpgrade(context, settings);
        }

        RootElevator.EnsureRootExectuion();
        var archNews = new ArchNews();
        archNews.ExecuteAsync(context, new ArchNewsSettings()).GetAwaiter().GetResult();

        AnsiConsole.MarkupLine("[yellow]Performing full system upgrade...[/]");

        var manager = new AlpmManager();
        object renderLock = new();

        manager.Replaces += (sender, args) =>
        {
            foreach (var replace in args.Replaces)
            {
                AnsiConsole.MarkupLine(
                    $"[magenta]Replacement:[/] [cyan]{args.Repository}/{args.PackageName}[/] replaces [red]{replace}[/]");
            }
        };

        manager.Question += (sender, args) =>
        {
            lock (renderLock)
            {
                AnsiConsole.WriteLine();
                QuestionHandler.HandleQuestion(args, Program.IsUiMode, settings.NoConfirm);
            }
        };

        AnsiConsole.MarkupLine("[yellow]Checking for system updates...[/]");
        AnsiConsole.MarkupLine("[yellow] Initializing and syncing repositories...[/]");
        manager.IntializeWithSync();
        var packagesNeedingUpdate = manager.GetPackagesNeedingUpdate();
        if (packagesNeedingUpdate.Count == 0)
        {
            AnsiConsole.MarkupLine("[green]System is up to date![/]");
            return 0;
        }

        var config = ConfigManager.ReadConfig();
        var parsed =
            (Shelly_CLI.Configuration.SizeDisplay)Enum.Parse(typeof(Shelly_CLI.Configuration.SizeDisplay),
                config.FileSizeDisplay);

        var table = new Table();
        table.AddColumn("Package");
        table.AddColumn("Current Version");
        table.AddColumn("New Version");
        table.AddColumn($"Download Size ({config.FileSizeDisplay})");
        foreach (var pkg in packagesNeedingUpdate)
        {
            table.AddRow(pkg.Name, pkg.CurrentVersion, pkg.NewVersion, CalculateDownside(parsed, pkg.DownloadSize));
        }

        AnsiConsole.Write(table);
        if (!settings.NoConfirm)
        {
            if (!AnsiConsole.Confirm("Do you want to proceed with system upgrade?"))
            {
                AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
                return 0;
            }
        }

        AnsiConsole.MarkupLine("[yellow] Starting System Upgrade...[/]");
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
                        var bar = new string('█', pct / 5) + new string('░', 20 - pct / 5);
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
                manager.SyncSystemUpdate();
            });

        AnsiConsole.MarkupLine("[green]System upgraded successfully![/]");
        manager.Dispose();
        if (settings.Aur || settings.All)
        {
            var aurCommand = new AurUpgradeCommand();
            var aurSettings = new AurUpgradeSettings()
            {
                NoConfirm = settings.NoConfirm
            };
            aurCommand.ExecuteAsync(context, aurSettings).GetAwaiter().GetResult();
        }

        if (settings.Flatpak || settings.All)
        {
            var flatpakCommand = new FlatpakUpgrade();
            flatpakCommand.Execute(context);
        }

        return 0;
    }

    private static int HandleUiModeUpgrade(CommandContext context, UpgradeSettings settings)
    {
        Console.Error.WriteLine("Performing full system upgrade...");

        var manager = new AlpmManager();
        object renderLock = new();

        manager.Replaces += (sender, args) =>
        {
            foreach (var replace in args.Replaces)
            {
                Console.Error.WriteLine(
                    $"Replacement: {args.Repository}/{args.PackageName} replaces {replace}");
            }
        };

        manager.Question += (sender, args) =>
        {
            lock (renderLock)
            {
                Console.Error.WriteLine();
                QuestionHandler.HandleQuestion(args, Program.IsUiMode, settings.NoConfirm);
            }
        };

        Console.Error.WriteLine("Checking for system updates...");
        Console.Error.WriteLine(" Initializing and syncing repositories...");
        manager.IntializeWithSync();
        var packagesNeedingUpdate = manager.GetPackagesNeedingUpdate();
        if (packagesNeedingUpdate.Count == 0)
        {
            Console.Error.WriteLine("System is up to date!");
            return 0;
        }

        Console.Error.WriteLine($"{packagesNeedingUpdate.Count} packages need updates:");
        foreach (var pkg in packagesNeedingUpdate)
        {
            Console.Error.WriteLine(
                $"  {pkg.Name}: {pkg.CurrentVersion} -> {pkg.NewVersion} ({pkg.DownloadSize} bytes)");
        }

        Console.Error.WriteLine(" Starting System Upgrade...");

        manager.Progress += (sender, args) =>
        {
            lock (renderLock)
            {
                var name = args.PackageName ?? "unknown";
                var pct = args.Percent ?? 0;
                var actionType = args.ProgressType;
                Console.Error.WriteLine($"{name}: {pct}% - {actionType}");
            }
        };

        manager.SyncSystemUpdate();
        manager.Dispose();
        if (settings.Aur || settings.All)
        {
            var aurCommand = new AurUpgradeCommand();
            var aurSettings = new AurUpgradeSettings()
            {
                NoConfirm = settings.NoConfirm,
            };
            aurCommand.ExecuteAsync(context, aurSettings).GetAwaiter().GetResult();
        }

        if (settings.Flatpak || settings.All)
        {
            var flatpakCommand = new FlatpakUpgrade();
            flatpakCommand.Execute(context);
        }

        Console.Error.WriteLine("System upgraded successfully!");
        manager.Dispose();
        return 0;
    }

    private static string CalculateDownside(SizeDisplay size, long downloadSize)
    {
        return size switch
        {
            SizeDisplay.Bytes => downloadSize.ToString(),
            SizeDisplay.Megabytes => (downloadSize / 1024).ToString(),
            SizeDisplay.Gigabytes => ((downloadSize / 1024) / 1024).ToString(),
            _ => downloadSize.ToString()
        };
    }
}