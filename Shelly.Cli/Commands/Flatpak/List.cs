using System.CommandLine;
using PackageManager.Flatpak;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Commands.Flatpak;

public class List : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("list", "List installed flatpak apps");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new List();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override ValueTask ExecuteAsync(IShellyConsole console)
    {
        var manager = new FlatpakManager();
        var packages = manager.SearchInstalled().OrderBy(p => p.Id).ToList();

        if (UiMode || JsonOutput)
        {
            JsonPackFrame.WriteToStdout(packages);
            return ValueTask.CompletedTask;
        }

        console.WriteLine(BasicTable.Execute(
            ["Name", "Id", "Version", "Arch", "Branch", "Summary", "Remote"], packages,
            p => p.Name,
            p => p.Id,
            p => p.Version,
            p => p.Arch,
            p => p.Branch,
            p => Truncate(p.Summary, 50),
            p => p.Remote));
        console.WriteLine(AnsiUtilities.Colorize($"Total: {packages.Count} packages", ConsoleColor.Blue));
        return ValueTask.CompletedTask;
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;

    private static string Truncate(string value, int max) =>
        value.Length <= max ? value : value[..max];
}
