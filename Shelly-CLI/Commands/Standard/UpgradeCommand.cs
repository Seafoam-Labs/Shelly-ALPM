using System.Diagnostics;
using PackageManager.Alpm;
using PackageManager.Utilities;
using Shelly_CLI.Commands.Aur;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;
using static System.Enum;

namespace Shelly_CLI.Commands.Standard;

public class UpgradeCommand : AsyncCommand<UpgradeSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, UpgradeSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeUpgrade(context, settings);
        }

        RootElevator.EnsureRootExectuion();
        var archNews = new ArchNews();
        await archNews.ExecuteAsync(context, new ArchNewsSettings());

        AnsiConsole.MarkupLine("[yellow]Performing full system upgrade...[/]");

        var manager = new AlpmManager();

        AnsiConsole.MarkupLine("[yellow]Checking for system updates...[/]");
        AnsiConsole.MarkupLine("[yellow]Initializing and syncing repositories...[/]");
        manager.Initialize(true);
        manager.Sync();
        var packagesNeedingUpdate = manager.GetPackagesNeedingUpdate();
        if (packagesNeedingUpdate.Count == 0)
        {
            AnsiConsole.MarkupLine("[green]Standard Packages are up to date![/]");
        }

        if (packagesNeedingUpdate.Count > 0)
        {
            var config = ConfigManager.ReadConfig();
            var sizeDisplay =
                (SizeDisplay)Parse(typeof(SizeDisplay),
                    config.FileSizeDisplay);


            var table = new Table().Border(TableBorder.None);


            table.AddColumn(new TableColumn($"[bold green]Package ({packagesNeedingUpdate.Count})[/]").LeftAligned());
            table.AddColumn(new TableColumn("[bold green]Old Version[/]").LeftAligned());
            table.AddColumn(new TableColumn("[bold green]New Version[/]").LeftAligned());
            table.AddColumn(new TableColumn("[bold green]Net Change[/]").RightAligned());
            table.AddColumn(new TableColumn("[bold green]Download Size[/]").RightAligned());

            long totalDownloadSize = 0;
            long totalNetChange = 0;
            long totalInstalledSize = 0;

            foreach (var pkg in packagesNeedingUpdate)
            {
                long netChangeBytes = pkg.SizeDifference;

                totalDownloadSize += pkg.DownloadSize;
                totalNetChange += netChangeBytes;

                table.AddRow(
                    $"[green]{Markup.Escape(pkg.Name)}[/]",
                    $"[green]{Markup.Escape(pkg.CurrentVersion)}[/]",
                    $"[green]{Markup.Escape(pkg.NewVersion)}[/]",
                    $"[green]{SizeHelper.FormatSize(netChangeBytes, sizeDisplay)}[/]",
                    $"[green]{SizeHelper.FormatSize(pkg.DownloadSize, sizeDisplay)}[/]"
                );
            }

            AnsiConsole.Write(table);
            AnsiConsole.WriteLine();
            AnsiConsole.MarkupLine($"[bold green]Total Download Size:[/]  {SizeHelper.FormatSize(totalDownloadSize, sizeDisplay),10}");
            AnsiConsole.MarkupLine($"[bold green]Net Upgrade Size:[/]     {SizeHelper.FormatSize(totalNetChange, sizeDisplay),10}");
            AnsiConsole.WriteLine();

            if (!settings.NoConfirm)
            {
                if (!AnsiConsole.Confirm("[bold green]:: Proceed with installation?[/]"))
                {
                    AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
                    return 0;
                }
            }

            AnsiConsole.MarkupLine("[yellow] Starting System Upgrade...[/]");
            var cfg = ConfigManager.ReadConfig();
            var useSinglePane = settings.SinglePane
                || string.Equals(cfg.OutputMode, "singlepane", StringComparison.OrdinalIgnoreCase)
                || Console.IsOutputRedirected;
            var upgradeResult = useSinglePane
                ? await StandardSinglePaneOutput.Output(manager, x => x.SyncSystemUpdate(), settings.NoConfirm)
                : await SplitOutput.Output(manager, x => x.SyncSystemUpdate(), settings.NoConfirm);
            manager.Dispose();
            if (!upgradeResult)
            {
                AnsiConsole.MarkupLine("[red]System upgrade failed. See errors above.[/]");
                return 1;
            }

            AnsiConsole.MarkupLine("[green]System upgraded successfully![/]");
        }

        if ((settings.Aur || settings.All) && ConfigManager.ReadConfig().AurEnabled)
        {
            var aurCommand = new AurUpgradeCommand();
            var aurSettings = new AurUpgradeSettings()
            {
                NoConfirm = settings.NoConfirm
            };
            var aurResult = await aurCommand.ExecuteAsync(context, aurSettings);
            if (aurResult != 0)
            {
                AnsiConsole.MarkupLine("[red]AUR upgrade failed.[/]");
            }
        }

        if ((settings.Flatpak || settings.All) && ConfigManager.ReadConfig().FlatPackEnabled)
        {
            var flatpakResult = ExecuteFlatpakUpdate();
            AnsiConsole.MarkupLine($"[yellow]{flatpakResult.EscapeMarkup()}[/]");
        }


        var (needsReboot, services) = RestartManager.CheckForRequiredRestarts();
        if (needsReboot)
        {
            AnsiConsole.MarkupLine("[bold red]⚠ A full system reboot is required![/]");
        }
        else if (services.Count > 0)
        {
            AnsiConsole.MarkupLine("[yellow]Restarting services...[/]");
            var failures = await RestartManager.RestartServicesAsync(services);
            if (failures.Count == 0)
            {
                AnsiConsole.MarkupLine("[green]All services restarted successfully.[/]");
            }
            else
            {
                AnsiConsole.MarkupLine("[bold red] The following services failed to restart:[/]");
                foreach (var (svc, error) in failures)
                    AnsiConsole.MarkupLine($"[red]  • {Markup.Escape(svc)}: {Markup.Escape(error)}[/]");
            }
        }

        return 0;
    }

    private static async Task<int> HandleUiModeUpgrade(CommandContext context, UpgradeSettings settings)
    {
        await Console.Error.WriteLineAsync("Performing full system upgrade...");

        var manager = new AlpmManager();
        object renderLock = new();

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
            lock (renderLock)
            {
                Console.Error.WriteLine();
                QuestionHandler.HandleQuestion(args, Program.IsUiMode, settings.NoConfirm);
            }
        };

        await Console.Error.WriteLineAsync("Checking for system updates...");
        await Console.Error.WriteLineAsync(" Initializing and syncing repositories...");
        manager.IntializeWithSync();
        var packagesNeedingUpdate = manager.GetPackagesNeedingUpdate();
        if (packagesNeedingUpdate.Count == 0)
        {
            await Console.Error.WriteLineAsync("Standard Packages are up to date!");
        }

        if (packagesNeedingUpdate.Count > 0)
        {
            await Console.Error.WriteLineAsync($"{packagesNeedingUpdate.Count} packages need updates:");
            foreach (var pkg in packagesNeedingUpdate)
            {
                await Console.Error.WriteLineAsync(
                    $"  {pkg.Name}: {pkg.CurrentVersion} -> {pkg.NewVersion} ({pkg.DownloadSize} bytes)");
            }

            await Console.Error.WriteLineAsync(" Starting System Upgrade...");

            manager.Progress += (_, args) =>
            {
                lock (renderLock)
                {
                    var name = args.PackageName ?? "unknown";
                    var pct = args.Percent ?? 0;
                    var actionType = args.ProgressType;
                    Console.Error.WriteLine($"{name}: {pct}% - {actionType}");
                }
            };

            manager.HookRun += (_, args) => { Console.Error.WriteLine($"[ALPM_HOOK]{args.Description}"); };

            bool hadError = false;
            manager.ErrorEvent += (_, e) =>
            {
                Console.Error.WriteLine($"[ALPM_ERROR]{e.Error}");
                hadError = true;
            };

            var result = await manager.SyncSystemUpdate();
            manager.Dispose();
            if (!result || hadError)
            {
                await Console.Error.WriteLineAsync("System upgrade failed.");
                return 1;
            }
        }

        if ((settings.Aur || settings.All) && ConfigManager.ReadConfig().AurEnabled)
        {
            var aurCommand = new AurUpgradeCommand();
            var aurSettings = new AurUpgradeSettings()
            {
                NoConfirm = settings.NoConfirm,
            };
            var aurResult = await aurCommand.ExecuteAsync(context, aurSettings);
            if (aurResult != 0)
            {
                await Console.Error.WriteLineAsync("AUR upgrade failed.");
            }
        }

        if ((settings.Flatpak || settings.All) && ConfigManager.ReadConfig().FlatPackEnabled)
        {
            var flatpakResult = ExecuteFlatpakUpdate();
            if (!string.IsNullOrEmpty(flatpakResult))
            {
                await Console.Error.WriteLineAsync(flatpakResult);
            }
        }

        var (needsReboot, services) = RestartManager.CheckForRequiredRestarts();
        if (needsReboot)
        {
            await Console.Error.WriteLineAsync("[RESTART_REQUIRED]reboot");
        }
        else if (services.Count > 0)
        {
            var failures = await RestartManager.RestartServicesAsync(services);
            foreach (var (svc, error) in failures)
                await Console.Error.WriteLineAsync($"[RESTART_FAILED]service:{svc}|{error}");
        }

        await Console.Error.WriteLineAsync("System upgraded successfully!");
        manager.Dispose();
        return 0;
    }

    //Execture as non-root so flatpaks upgrade correctly.
    private static string ExecuteFlatpakUpdate()
    {
        var sudoUser = Environment.GetEnvironmentVariable("SUDO_USER");

        var exe = Environment.ProcessPath ?? Environment.GetCommandLineArgs()[0];

        var startInfo = new ProcessStartInfo
        {
            FileName = "sudo",
            Arguments = $"-u {sudoUser} {exe} flatpak upgrade",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        using var process = Process.Start(startInfo);
        if (process == null) return "Failed to start non-root Flatpak update process.";

        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();

        return process.ExitCode != 0 ? $"Flatpak update failed (Exit {process.ExitCode}): {error}" : output;
    }
}