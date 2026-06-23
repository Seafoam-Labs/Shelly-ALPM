using System.CommandLine;
using System.Text.Json;
using PackageManager.Flatpak;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Commands.Flatpak;

public class ListUpdates : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("list-updates", "List flatpak apps with updates");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new ListUpdates();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override ValueTask ExecuteAsync(IShellyConsole console)
    {
        var packages = FlatpakManager.GetPackagesWithUpdates(true).OrderBy(p => p.Id).ToList();

        if (UiMode)
        {
            JsonPackFrame.WriteToStdout(packages);
            return ValueTask.CompletedTask;
        }

        if (JsonOutput)
        {
            console.WriteLine(JsonSerializer.Serialize(packages, ShellyCliJsonContext.Default.ListFlatpakPackageDto));
            return ValueTask.CompletedTask;
        }

        console.WriteLine(BasicTable.Execute(
            ["Name", "Id", "Version", "Permissions"], packages,
            p => p.Name,
            p => p.Id,
            p => p.Version,
            p => p.Permissions.Count > 0 ? string.Join("\n", p.Permissions) : "No changes"));
        console.WriteLine(AnsiUtilities.Colorize($"Total: {packages.Count} packages", ConsoleColor.Blue));
        return ValueTask.CompletedTask;
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;
}
