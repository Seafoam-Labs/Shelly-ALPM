using System.CommandLine;
using System.Text.Json;
using PackageManager.Aur;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Commands.Aur;

public class ListInstalled : GlobalSettingsCommand
{
    private bool ShowHidden { get; set; }

    public static Command Create()
    {
        var showHidden = new Option<bool>("--show-hidden")
            { Description = "Include hidden packages in the listing" };

        var command = new Command("list", "List installed AUR packages")
        {
            showHidden
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new ListInstalled
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
        using var manager = new AurPackageManager();
        await manager.Initialize(showHiddenPackages: ShowHidden);

        var packages = await manager.GetInstalledPackages();
        var sorted = packages.OrderBy(p => p.Name).ToList();

        if (UiMode)
        {
            JsonPackFrame.WriteToStdout(sorted);
            return;
        }

        if (JsonOutput)
        {
            console.WriteLine(JsonSerializer.Serialize(sorted, ShellyCliJsonContext.Default.ListAurPackageDto));
            return;
        }

        console.WriteLine(BasicTable.Execute(
            ["Name", "Version", "Description"], sorted,
            p => p.Name,
            p => p.Version,
            p => Truncate(p.Description ?? "", 60)));
        console.WriteLine(AnsiUtilities.Colorize(
            $"Total: {packages.Count} AUR packages installed", ConsoleColor.Blue));
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;

    private static string Truncate(string value, int max) =>
        value.Length <= max ? value : value[..max];
}
