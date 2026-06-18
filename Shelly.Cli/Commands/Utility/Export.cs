using System.CommandLine;
using System.Text.Json;
using PackageManager.Alpm;
using PackageManager.Aur;
using PackageManager.Flatpak;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Cli.Models.Sync;
using Shelly.Utilities;


namespace Shelly.Cli.Commands.Utility;

public partial class Export : GlobalSettingsCommand
{
    public string? Name { get; set; }

    public string? Output { get; set; }

    public static Command Create()
    {
        var name = new Option<string?>("--name", "-a") { Description = "The name of the exported file" };
        var output = new Option<string?>("--output", "-o") { Description = "The default output location for the sync file" };

        var command = new Command("export", "Export the current system state to a file") { name, output };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new Export
            {
                Name = parseResult.GetValue(name),
                Output = parseResult.GetValue(output)
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        var time = DateTimeOffset.Now;
        var fileName = string.IsNullOrEmpty(Name) ? $"{time:yyyyMMddHHmmss}_shelly.sync" : Name + ".sync";

        var path = string.IsNullOrEmpty(Output)
            ? XdgPaths.ShellyCache(fileName)
            : Path.Combine(Output, fileName);

        //Alpm 
        using var manager = new AlpmManager();
        var packages = manager.GetInstalledPackages();

        //Aur
        AurPackageManager? AurManager = null;
        AurManager = new AurPackageManager();
        await AurManager.Initialize();
        var aurPackages = await AurManager.GetInstalledPackages();
        AurManager.Dispose();

        //Flatpaks
        var flatpak = new FlatpakManager();
        var flatpaks = flatpak.SearchInstalled();

        var syncModel = new Sync
        (
            new SyncMetaData
            {
                Date = time.ToString("yyyy-MM-dd"),
                Time = time.ToUnixTimeSeconds()
            },
            packages.Select(x => new SyncStandard(x.Name,x.Version)).ToList(),
            aurPackages.Select(x => new SyncAur(x.Name,x.Version)).ToList(),
            flatpaks.Select(x => new SyncFlatpak(x.Id,x.Version)).ToList()
        );

        var json = JsonSerializer.Serialize(syncModel, ShellyCliJsonContext.Default.Sync);

        Console.WriteLine(json);

        await File.WriteAllTextAsync(path, json);

        console.WriteLine(AnsiUtilities.SupportsAnsi ? $"Sync file exported to: {path}".Pastel(ConsoleColor.Blue) : $"Sync file exported to: {path}");
        
    }

    public override ValueTask ExecuteUiMode()
    {
        //Unneeded as the command is not interactive.
        throw new NotImplementedException();
    }
}