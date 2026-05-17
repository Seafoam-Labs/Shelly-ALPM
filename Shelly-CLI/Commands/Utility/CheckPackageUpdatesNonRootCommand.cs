using System.Text.Json;
using PackageManager.Alpm;
using PackageManager.Aur;
using PackageManager.Utilities;
using PackageManager.Aur.Models;
using PackageManager.Flatpak;
using PackageManager.Wire;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Utility;

public class CheckPackageUpdatesNonRootCommand : AsyncCommand<CheckPackageUpdatesNonRootSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, CheckPackageUpdatesNonRootSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeCheckUpdates(settings);
        }

        var alpmManager = new AlpmManager();
        List<AlpmPackageUpdateDto> alpmPackages = [];
        var aurManager = new AurPackageManager();
        List<AurUpdateDto> aurPackages = [];
        List<FlatpakPackageDto> flatpakPackages = [];
        var dbPath = XdgPaths.ShellyCache("db");
        Directory.CreateDirectory(dbPath);
        AnsiConsole.WriteLine(dbPath);
        if (settings is { Count: true, JsonOutput: false })
        {
            alpmManager.Initialize(useTempPath: true, tempPath: dbPath);
            alpmManager.Sync();
            alpmPackages = alpmManager.GetPackagesNeedingUpdate();
            alpmManager.Dispose();
            var syncModel = new SyncModel();
            List<SyncPackageModel> syncPackageModels = [];
            syncPackageModels.AddRange(alpmPackages.Select(pkg => new SyncPackageModel()
            {
                Name = pkg.Name, DownloadSize = FormatSize(pkg.DownloadSize), OldVersion = pkg.CurrentVersion,
                Version = pkg.NewVersion
            }));

            syncModel.Packages = syncPackageModels;
            if (settings.CheckAur)
            {
                await aurManager.Initialize(false, true, tempPath: dbPath);
                aurPackages = await aurManager.GetPackagesNeedingUpdate();
                aurManager.Dispose();
                List<SyncAurModel> aurPackageModels = [];
                aurPackageModels.AddRange(aurPackages.Select(pkg => new SyncAurModel()
                    { Name = pkg.Name, OldVersion = pkg.Version, Version = pkg.NewVersion }));
                syncModel.Aur = aurPackageModels;
            }

            if (settings.CheckFlatpak)
            {
                flatpakPackages = FlatpakManager.GetPackagesWithUpdates();
                List<SyncFlatpakModel> flatpakPackageModels = [];
                flatpakPackageModels.AddRange(flatpakPackages.Select(pkg => new SyncFlatpakModel()
                    { Id = pkg.Id, Name = pkg.Name, Version = pkg.Version }));
                syncModel.Flatpaks = flatpakPackageModels;
            }

            AnsiConsole.MarkupLine(
                $"[green]Updates available count {syncModel.Packages.Count + syncModel.Aur.Count + syncModel.Flatpaks.Count} [/]");
            return 0;
        }

        if (settings.JsonOutput)
        {
            alpmManager.Initialize(useTempPath: true, tempPath: dbPath);
            alpmManager.Sync();
            alpmPackages = alpmManager.GetPackagesNeedingUpdate();
            alpmManager.Dispose();
            var syncModel = new SyncModel();
            List<SyncPackageModel> syncPackageModels = [];
            syncPackageModels.AddRange(alpmPackages.Select(pkg => new SyncPackageModel()
            {
                Name = pkg.Name, DownloadSize = FormatSize(pkg.DownloadSize), OldVersion = pkg.CurrentVersion,
                Version = pkg.NewVersion
            }));

            syncModel.Packages = syncPackageModels;
            if (settings.CheckAur)
            {
                await aurManager.Initialize(false, true, tempPath: dbPath);
                aurPackages = await aurManager.GetPackagesNeedingUpdate();
                aurManager.Dispose();
                List<SyncAurModel> aurPackageModels = [];
                aurPackageModels.AddRange(aurPackages.Select(pkg => new SyncAurModel()
                    { Name = pkg.Name, OldVersion = pkg.Version, Version = pkg.NewVersion }));
                syncModel.Aur = aurPackageModels;
            }

            if (settings.CheckFlatpak)
            {
                flatpakPackages = FlatpakManager.GetPackagesWithUpdates();
                List<SyncFlatpakModel> flatpakPackageModels = [];
                flatpakPackageModels.AddRange(flatpakPackages.Select(pkg => new SyncFlatpakModel()
                    { Id = pkg.Id, Name = pkg.Name, Version = pkg.Version }));
                syncModel.Flatpaks = flatpakPackageModels;
            }

            var json = JsonSerializer.Serialize(syncModel, ShellyCLIJsonContext.Default.SyncModel);
            // Write directly to stdout stream to bypass Spectre.Console redirection
            await using var stdout = Console.OpenStandardOutput();
            await using var writer = new System.IO.StreamWriter(stdout, System.Text.Encoding.UTF8);
            await writer.WriteLineAsync(json);
            await writer.FlushAsync();
            if (settings.Count)
            {
                AnsiConsole.MarkupLine(
                    $"[green]Updates available count {syncModel.Packages.Count + syncModel.Aur.Count + syncModel.Flatpaks.Count}[/]s");
            }

            return 0;
        }

        AnsiConsole.Status().Spinner(Spinner.Known.BouncingBall).Start("Initializing and syncing ALPM updates",
            _ =>
            {
                alpmManager.Initialize(useTempPath: true, tempPath: dbPath);
                alpmManager.Sync();
                alpmPackages = alpmManager.GetPackagesNeedingUpdate();
                alpmManager.Dispose();
            });
        AnsiConsole.MarkupLine("[green]Finished checking Standard[/]");
        if (settings.CheckAur)
        {
            AnsiConsole.Status().Spinner(Spinner.Known.BouncingBall).Start("Initializing and syncing AUR packages",
                async _ =>
                {
                    await aurManager.Initialize(false, true, tempPath: dbPath);
                    aurPackages = await aurManager.GetPackagesNeedingUpdate();
                    aurManager.Dispose();
                });
            AnsiConsole.MarkupLine("[green]Finished checking AUR[/]");
        }

        if (settings.CheckFlatpak)
        {
            AnsiConsole.Status().Spinner(Spinner.Known.BouncingBall).Start(
                "Initializing and syncing Flatpak packages",
                _ => { flatpakPackages = FlatpakManager.GetPackagesWithUpdates(); });
            AnsiConsole.MarkupLine("[green]Finished checking Flatpak[/]");
        }

        var table = new Table().AddColumns("Name", "Type", "New Version", "Current Version", "Download Size");
        foreach (var alpm in alpmPackages)
        {
            table.AddRow(alpm.Name, "Standard", alpm.NewVersion, alpm.CurrentVersion,
                FormatSize(alpm.DownloadSize));
        }

        foreach (var pkg in aurPackages)
        {
            table.AddRow(pkg.Name, "AUR", pkg.NewVersion, pkg.Version, FormatSize(pkg.DownloadSize));
        }

        foreach (var pkg in flatpakPackages)
        {
            table.AddRow(pkg.Name, "Flatpak", pkg.Version, "", "");
        }

        AnsiConsole.Write(table);


        return 0;
    }

    private static string FormatSize(long bytes)
    {
        string[] sizes = ["B", "KB", "MB", "GB"];
        int order = 0;
        double size = bytes;
        while (size >= 1024 && order < sizes.Length - 1)
        {
            order++;
            size /= 1024;
        }

        return $"{size:0.##} {sizes[order]}";
    }

    private static async Task<int> HandleUiModeCheckUpdates(CheckPackageUpdatesNonRootSettings settings)
    {
        var alpmManager = new AlpmManager();
        List<AlpmPackageUpdateDto> alpmPackages;
        var aurManager = new AurPackageManager();
        List<AurUpdateDto> aurPackages = [];
        List<FlatpakPackageDto> flatpakPackages = [];
        var dbPath = XdgPaths.ShellyCache("db");
        Directory.CreateDirectory(dbPath);

        if (settings.JsonOutput)
        {
            alpmManager.Initialize(useTempPath: true, tempPath: dbPath);
            alpmManager.Sync();
            alpmPackages = alpmManager.GetPackagesNeedingUpdate();
            alpmManager.Dispose();
            var syncModel = new SyncModel();
            List<SyncPackageModel> syncPackageModels = [];
            syncPackageModels.AddRange(alpmPackages.Select(pkg => new SyncPackageModel()
            {
                Name = pkg.Name, DownloadSize = FormatSize(pkg.DownloadSize), OldVersion = pkg.CurrentVersion,
                Version = pkg.NewVersion
            }));

            syncModel.Packages = syncPackageModels;
            if (settings.CheckAur)
            {
                await aurManager.Initialize(false, true, tempPath: dbPath);
                aurPackages = await aurManager.GetPackagesNeedingUpdate();
                aurManager.Dispose();
                List<SyncAurModel> aurPackageModels = [];
                aurPackageModels.AddRange(aurPackages.Select(pkg => new SyncAurModel()
                    { Name = pkg.Name, OldVersion = pkg.Version, Version = pkg.NewVersion }));
                syncModel.Aur = aurPackageModels;
            }

            if (settings.CheckFlatpak)
            {
                flatpakPackages = FlatpakManager.GetPackagesWithUpdates();
                List<SyncFlatpakModel> flatpakPackageModels = [];
                flatpakPackageModels.AddRange(flatpakPackages.Select(pkg => new SyncFlatpakModel()
                    { Id = pkg.Id, Name = pkg.Name, Version = pkg.Version }));
                syncModel.Flatpaks = flatpakPackageModels;
            }

            JsonPackFrame.WriteToStdout(syncModel);
            return 0;
        }

        await Console.Error.WriteLineAsync("Initializing and syncing ALPM updates");
        alpmManager.Initialize(useTempPath: true, tempPath: dbPath);
        alpmManager.Sync();
        alpmPackages = alpmManager.GetPackagesNeedingUpdate();
        alpmManager.Dispose();
        await Console.Error.WriteLineAsync("Finished checking Standard");

        if (settings.CheckAur)
        {
            await Console.Error.WriteLineAsync("Initializing AUR packages");
            await aurManager.Initialize(false, true, tempPath: dbPath);
            aurPackages = await aurManager.GetPackagesNeedingUpdate();
            aurManager.Dispose();
            await Console.Error.WriteLineAsync("Finished checking AUR");
        }

        if (settings.CheckFlatpak)
        {
            await Console.Error.WriteLineAsync("Initializing and syncing Flatpak packages");
            flatpakPackages = FlatpakManager.GetPackagesWithUpdates();
            await Console.Error.WriteLineAsync("Finished checking Flatpak");
        }

        foreach (var alpm in alpmPackages)
        {
            Console.WriteLine(
                $"{alpm.Name} Standard {alpm.NewVersion} {alpm.CurrentVersion} {FormatSize(alpm.DownloadSize)}");
        }

        foreach (var pkg in aurPackages)
        {
            Console.WriteLine($"{pkg.Name} AUR {pkg.NewVersion} {pkg.Version} {FormatSize(pkg.DownloadSize)}");
        }

        foreach (var pkg in flatpakPackages)
        {
            Console.WriteLine($"{pkg.Name} Flatpak {pkg.Version}");
        }

        return 0;
    }
}