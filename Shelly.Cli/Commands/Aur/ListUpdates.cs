using System.CommandLine;
using PackageManager.Aur;
using Shelly.Cli.Interactions;
using Shelly.Utilities;

namespace Shelly.Cli.Commands.Aur;

public class ListUpdates : GlobalSettingsCommand
{
    private bool ShowHidden { get; set; }

    public static Command Create()
    {
        var showHidden = new Option<bool>("--show-hidden")
            { Description = "Include hidden packages in the listing" };

        var command = new Command("list-updates", "List AUR packages that have available updates")
        {
            showHidden
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new ListUpdates
            {
                ShowHidden = parseResult.GetValue(showHidden)
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        var dbPath = XdgPaths.ShellyCache("db");
        XdgPaths.EnsureDirectory(dbPath);

        using var manager = new AurPackageManager();
        await manager.Initialize(showHiddenPackages: ShowHidden, tempPath: dbPath, useTempPath: true);

        var updates = await manager.GetPackagesNeedingUpdate();
        var sorted = updates.OrderBy(p => p.Name).ToList();

        if (UiMode || JsonOutput)
        {
            JsonPackFrame.WriteToStdout(sorted);
            return;
        }

        if (sorted.Count == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("All AUR packages are up to date.", ConsoleColor.Green));
            return;
        }

        console.WriteLine(BasicTable.Execute(
            ["Name", "Installed", "Available", "Description"], sorted,
            p => p.Name,
            p => p.Version,
            p => p.NewVersion,
            p => Truncate(GetDefaultDescription(p.Description), 50)));
        console.WriteLine(AnsiUtilities.Colorize(
            $"Total: {sorted.Count} packages need updates", ConsoleColor.Blue));
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;

    private static string GetDefaultDescription(string description) =>
        string.IsNullOrWhiteSpace(description) ? "No Description Available" : description;

    private static string Truncate(string value, int max) =>
        value.Length <= max ? value : value[..max];
}
