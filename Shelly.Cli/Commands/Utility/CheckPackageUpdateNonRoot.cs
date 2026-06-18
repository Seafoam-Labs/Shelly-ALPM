using System.CommandLine;
using System.Text.Json;
using PackageManager.Alpm;
using PackageManager.Aur;
using PackageManager.Flatpak;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Cli.Models.Sync;
using Shelly.Utilities;
using Shelly.Utilities.Enums;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.Utility;

public partial class CheckPackageUpdateNonRoot : GlobalSettingsCommand
{
    private bool Aur { get; set; }

    private bool Flatpak { get; set; }

    private bool Count { get; set; }

    public static Command Create()
    {
        var aur = new Option<bool>("--aur", "-a") { Description = "Check for AUR updates" };
        var flatpak = new Option<bool>("--flatpak", "-l") { Description = "Check for Flatpak updates" };
        var count = new Option<bool>("--count", "-c") { Description = "Returns the number of updates" };

        var command = new Command("check-updates", "Check for package updates") { aur, flatpak, count };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new CheckPackageUpdateNonRoot
            {
                Aur = parseResult.GetValue(aur),
                Flatpak = parseResult.GetValue(flatpak),
                Count = parseResult.GetValue(count)
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        string message;
        var isAnsiSupported = AnsiUtilities.SupportsAnsi;
        var config = ConfigManager.ReadConfig();
        var sizeDisplay = Enum.Parse<SizeDisplay>(config.FileSizeDisplay);
        var dbPath = XdgPaths.ShellyCache("db");
        Directory.CreateDirectory(dbPath);
        if (Verbose)
        {
            message = isAnsiSupported ? $"Using {dbPath}".Pastel(ConsoleColor.Green) : $"Using {dbPath}";
            console.WriteLine(message);
        }

        message = isAnsiSupported ? "Checking for updates...".Pastel(ConsoleColor.Green) : "Checking for updates...";
        console.WriteLine(message);

        var standard = GetSyncStandards(dbPath, sizeDisplay);
        List<SyncAur> aurSync = [];
        if (Aur)
        {
            aurSync = await GetSyncAur(dbPath, sizeDisplay);
        }

        List<SyncFlatpak> flatpakSync = [];
        if (Flatpak)
        {
            flatpakSync = GetSyncFlatpak();
        }

        if (Count && !JsonOutput)
        {
            CountOutput(console, isAnsiSupported, standard.Count, aurSync.Count, flatpakSync.Count);
            return;
        }

        var sync = new Sync(
            new SyncMetaData("v1", DateTimeOffset.Now.Date.ToShortDateString(), DateTimeOffset.Now.ToUnixTimeSeconds()),
            standard, aurSync, flatpakSync);
        if (JsonOutput)
        {
            var json = JsonSerializer.Serialize(sync, ShellyCliJsonContext.Default.Sync);
            console.WriteLine(json);
            return;
        }

        message = isAnsiSupported ? "Updates found:".Pastel(ConsoleColor.Green) : "Updates found:";
        console.WriteLine(message);
        message = isAnsiSupported ? "Type: Standard".Pastel(ConsoleColor.Green) : "Type: Standard";
        console.WriteLine(message);
        var standardTable = BasicTable.Execute(["Name", "New Version", "Current Version", "Download Size"],
            sync.Packages, p => p.Name,
            p => p.Version,
            p => p.OldVersion,
            p => p.DownloadSize);
        console.Write(standardTable);
        console.WriteLine();
        message = isAnsiSupported ? "Type: AUR".Pastel(ConsoleColor.Green) : "Type: AUR";
        console.WriteLine(message);
        var aurTable = BasicTable.Execute(["Name", "New Version", "Current Version", "Download Size"], sync.Aur,
            p => p.Name,
            p => p.Version,
            p => p.OldVersion,
            p => p.DownloadSize);
        console.Write(aurTable);
        console.WriteLine();
        message = isAnsiSupported ? "Type: Flatpak".Pastel(ConsoleColor.Green) : "Type: Flatpak";
        console.WriteLine(message);
        var flatpakTable = BasicTable.Execute(["Name", "Id", "Version"], sync.Flatpak, p => p.Name,
            p => p.Id,
            p => p.Version);
        console.Write(flatpakTable);
        console.WriteLine();
    }

    public override async ValueTask ExecuteUiMode()
    {
        List<SyncStandard> standard = [];
        List<SyncAur> aur = [];
        List<SyncFlatpak> flatpak = [];
        var dbPath = XdgPaths.ShellyCache("db");
        Directory.CreateDirectory(dbPath);
        var config = ConfigManager.ReadConfig();
        var sizeDisplay = Enum.Parse<SizeDisplay>(config.FileSizeDisplay);
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(AlpmEvents.InformationalOutput,
            "Initializing and syncing ALPM updates"));
        standard = GetSyncStandards(dbPath, sizeDisplay);
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            AlpmEvents.InformationalOutput, "Finished checking Standard"));
        if (Aur)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                AlpmEvents.InformationalOutput, "Initializing AUR packages"));
            aur = await GetSyncAur(dbPath, sizeDisplay);
            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                AlpmEvents.InformationalOutput, "Finished checking AUR"));
        }

        if (Flatpak)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                AlpmEvents.InformationalOutput, "Initializing and syncing Flatpak packages"));
            flatpak = GetSyncFlatpak();
            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                AlpmEvents.InformationalOutput, "Finished checking Flatpak"));
        }

        var sync = new Sync(
            new SyncMetaData("v1", DateTimeOffset.Now.Date.ToShortDateString(), DateTimeOffset.Now.ToUnixTimeSeconds()),
            standard, aur, flatpak);
        JsonPackFrame.WriteToStdout(sync);
    }

    private void CountOutput(IShellyConsole console, bool isAnsiSupported, int standardCount, int aurCount, int flatpakCount)
    {
        var message = isAnsiSupported
            ? $"Updates found: {standardCount + aurCount + flatpakCount} ".Pastel(ConsoleColor.Green)
            : $"Updates found: {standardCount + aurCount + flatpakCount}";
        console.WriteLine(message);
    }

    private List<SyncStandard> GetSyncStandards(string tempPath, SizeDisplay sizeDisplay = SizeDisplay.Bytes)
    {
        var alpmManager = new AlpmManager();
        alpmManager.Initialize(useTempPath: true, tempPath: tempPath);
        alpmManager.Sync();
        var alpmPackages = alpmManager.GetPackagesNeedingUpdate();
        alpmManager.Dispose();
        return alpmPackages.Select(pkg => new SyncStandard(pkg.Name, pkg.NewVersion, pkg.CurrentVersion,
            SizeUtilities.FormatSize(sizeDisplay, pkg.DownloadSize)
        )).ToList();
    }

    private async Task<List<SyncAur>> GetSyncAur(string tempPath, SizeDisplay sizeDisplay = SizeDisplay.Bytes)
    {
        var aurManager = new AurPackageManager();
        await aurManager.Initialize(false, useTempPath: true, tempPath: tempPath);
        var packages = await aurManager.GetPackagesNeedingUpdate();
        aurManager.Dispose();
        return packages.Select(pkg => new SyncAur(pkg.Name, pkg.NewVersion, pkg.Version,
            SizeUtilities.FormatSize(sizeDisplay, pkg.DownloadSize))).ToList();
    }

    private List<SyncFlatpak> GetSyncFlatpak(SizeDisplay sizeDisplay = SizeDisplay.Bytes)
    {
        var flatpak = FlatpakManager.GetPackagesWithUpdates();
        return flatpak.Select(pkg => new SyncFlatpak(pkg.Id, pkg.Name, pkg.Version)).ToList();
    }
}