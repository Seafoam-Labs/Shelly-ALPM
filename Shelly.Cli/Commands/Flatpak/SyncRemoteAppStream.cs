using System.CommandLine;
using PackageManager.Flatpak;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class SyncRemoteAppStream : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("sync-remote-appstream", "Sync remote appstream");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new SyncRemoteAppStream();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override ValueTask ExecuteAsync(IShellyConsole console)
    {
        var (result, stringResult) = new FlatpakManager().UpdateAppstream();
        console.WriteLine(result
            ? Colorize(stringResult, ConsoleColor.Green)
            : Colorize(stringResult, ConsoleColor.Red));
        return ValueTask.CompletedTask;
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;
}
