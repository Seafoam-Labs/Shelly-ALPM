// ReSharper disable InconsistentNaming
// ReSharper disable UnresolvedMemberInNamespace

using System;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using ConsoleAppFramework;
using PackageManager.Alpm;
using PackageManager.Aur;
using PackageManager.Flatpak;
using Shelly.Models;

// ReSharper disable InvalidXmlDocComment

namespace Shelly.Commands;

[RegisterCommands]
[SuppressMessage("GenerateConsoleAppFramework", "CAF007:Command name is duplicated.")]
internal class Utility
{
    /// <summary>
    /// Exports all installed packages. File will be named {yyyyMMddHHmmss}_shelly.sync with that date time being your
    /// local timezone.
    /// </summary>
    /// <param name="destination">-d, destination of file export. If unset will default to ~/{USER}/.cache/shelly</param>
    public async Task Export(ConsoleAppContext context, string? destination = null)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        var username = Environment.GetEnvironmentVariable("USER");
        if (string.IsNullOrEmpty(username) || username == "root")
        {
            username = Environment.GetEnvironmentVariable("SUDO_USER");
        }

        var time = DateTimeOffset.Now;
        Directory.CreateDirectory(Path.Combine("/home", username!, "Documents", "shelly"));

        var path = string.IsNullOrEmpty(destination)
            ? Path.Combine("/home", username!, "Documents", "shelly", $"{time:yyyyMMddHHmmss}_shelly.sync")
            : Path.GetFullPath(destination);

        //Standard
        var manager = new AlpmManager(Configuration.GetConfigurationFile());
        var packages = manager.GetInstalledPackages();
        manager.Dispose();

        //Aur
        var aurManager = new AurPackageManager(Configuration.GetConfigurationFile());
        await aurManager.Initialize();
        var aurPackages = await aurManager.GetInstalledPackages();
        aurManager.Dispose();

        var flatpak = new FlatpakManager();
        var flatpaks = flatpak.SearchInstalled();

        var syncModel = new SyncModel
        {
            MetaData = new SyncMetaData()
            {
                Date = time.ToString("yyyy-M-d dddd"),
                Time = time.ToUnixTimeMilliseconds()
            },
            Packages = packages.Select(x => new SyncPackageModel { Name = x.Name, Version = x.Version }).ToList(),
            Aur = aurPackages.Select(x => new SyncAurModel { Name = x.Name, Version = x.Version }).ToList(),
            Flatpaks = flatpaks.Select(x => new SyncFlatpakModel { Id = x.Id, Version = x.Version }).ToList()
        };
        var json = JsonSerializer.Serialize(syncModel, ShellyJsonContext.Default.SyncModel);
        Console.WriteLine(json);
        await File.WriteAllTextAsync(path, json);
        Console.WriteLine($"Sync file exported to: {path}");
    }
}