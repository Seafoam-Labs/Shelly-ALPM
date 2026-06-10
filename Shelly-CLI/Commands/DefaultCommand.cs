using System.Text.Json;
using PackageManager.Alpm;
using PackageManager.Aur;
using PackageManager.Aur.Models;
using Shelly_CLI.Commands.Aur;
using Shelly_CLI.Commands.Flatpak;
using Shelly_CLI.Commands.Standard;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;
using static Shelly_CLI.Configuration.DefaultCommand;

namespace Shelly_CLI.Commands;

internal sealed record PackageChoice(string Name, string Version, string Repo, bool IsExit = false)
{
    public static PackageChoice Exit { get; } = new("", "", "", true);
}

public class DefaultCommand : AsyncCommand<DefaultCommandSettings>
{
    // No Confirm is not implemented for default command by design
    public override async Task<int> ExecuteAsync(CommandContext context, DefaultCommandSettings settings)
    {
        if (settings.Version)
        {
            new VersionCommand().Execute(context);
            return 0;
        }

        var configPath = XdgPaths.ShellyConfig("config.json");
        if (!File.Exists(configPath)) return 1;

        var json = await File.ReadAllTextAsync(configPath);

        var config = JsonSerializer.Deserialize<ShellyConfig>(json, ShellyCLIJsonContext.Default.ShellyConfig);
        if (config == null) return 1;

        if (!string.IsNullOrEmpty(settings.SearchString))
        {
            RootElevator.EnsureRootExectuion();
            var standard = SearchStandard(settings.SearchString);
            var aur = await SearchAur(settings.SearchString);

            var choices = new List<PackageChoice>();
            choices.AddRange(standard.Select(x => new PackageChoice(x.Name, x.Version, "Standard")));
            choices.AddRange(aur.Select(x => new PackageChoice(x.Name, x.Version, "AUR")));
            choices.Add(PackageChoice.Exit);

            var selection = AnsiConsole.Prompt(
                new SelectionPrompt<PackageChoice>()
                    .Title($"[yellow]Found {standard.Count + aur.Count} packages please select one to install[/]")
                    .AddChoices(choices)
                    .UseConverter(choice => choice.IsExit
                        ? "[yellow]Exit[/]"
                        : $"{choice.Name} : {choice.Version} : {choice.Repo}"));

            if (selection.IsExit) return 0;

            if (selection.Repo == "AUR")
                await new AurInstallCommand().ExecuteAsync(context, new AurInstallSettings
                {
                    Packages = [selection.Name]
                });
            else
                await new InstallCommand().ExecuteAsync(context, new InstallPackageSettings
                {
                    Packages = [selection.Name]
                });

            return 0;
        }

        var command = Enum.Parse<Configuration.DefaultCommand>(config.DefaultExecution);
        return command switch
        {
            UpgradeStandard => await new UpgradeCommand().ExecuteAsync(context, new UpgradeSettings()),
            UpgradeFlatpak => new FlatpakUpgrade().Execute(context),
            UpgradeAur => await new AurUpgradeCommand().ExecuteAsync(context, new AurUpgradeSettings()),
            UpgradeAll => await new UpgradeCommand().ExecuteAsync(context, new UpgradeSettings { All = true }),
            Sync => new SyncCommand().Execute(context, new SyncSettings()),
            SyncForce => new SyncCommand().Execute(context, new SyncSettings { Force = true }),
            ListInstalled => new ListInstalledCommand().Execute(context, new AlpmListSettings()),
            _ => 1
        };
    }

    private static List<AlpmPackageDto> SearchStandard(string filter)
    {
        var manager = new AlpmManager();
        manager.Initialize();
        var packages = manager.GetAvailablePackages();
        packages = packages.Select(x => new { Package = x, Score = StringMatching.PartialRatio(filter, x.Name) })
            .Where(x => x.Score >= 75)
            .OrderByDescending(x => x.Score)
            .Select(x => x.Package)
            .Take(5) //Add configuration here to control amount visible.
            .ToList();
        manager.Dispose();
        return packages;
    }

    private static async Task<List<AurPackageDto>> SearchAur(string filter)
    {
        var manager = new AurPackageManager();
        await manager.Initialize();
        var packages = await manager.SearchPackages(filter);
        packages = packages.Select(x => new { Package = x, Score = StringMatching.PartialRatio(filter, x.Name) })
            .Where(x => x.Score >= 75)
            .OrderByDescending(x => x.Score)
            .Select(x => x.Package)
            .Take(5) //Add configuration here to control amount visible.
            .ToList();
        manager.Dispose();
        return packages;
    }
}