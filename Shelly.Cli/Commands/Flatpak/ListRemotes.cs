using System.CommandLine;
using PackageManager.Flatpak;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class ListRemotes : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("list-remotes", "Returns all remotes currently added");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new ListRemotes();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override ValueTask ExecuteAsync(IShellyConsole console)
    {
        var manager = new FlatpakManager();
        var remotes = manager.ListRemotesWithDetails();

        if (UiMode || JsonOutput)
        {
            JsonPackFrame.WriteToStdout(remotes);
            return ValueTask.CompletedTask;
        }

        console.WriteLine(Colorize("Remotes:", ConsoleColor.Blue));
        foreach (var remote in remotes)
        {
            var scopeColor = remote.Scope == "system" ? ConsoleColor.Green : ConsoleColor.Yellow;
            console.WriteLine($"{remote.Name} {Colorize($"({remote.Scope})", scopeColor)}");
        }

        return ValueTask.CompletedTask;
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;
}
