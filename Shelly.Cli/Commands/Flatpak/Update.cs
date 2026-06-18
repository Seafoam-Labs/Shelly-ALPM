using System.CommandLine;
using PackageManager.Flatpak;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class Update : GlobalSettingsCommand
{
    private string Package { get; set; } = string.Empty;

    public static Command Create()
    {
        var package = new Argument<string>("package") { Description = "Flatpak application ID (e.g., com.spotify.Client)" };

        var command = new Command("update", "Update flatpak app")
        {
            package
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Update
            {
                Package = parseResult.GetValue(package) ?? string.Empty
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

        console.WriteLine(Colorize("Updating flatpak app...", ConsoleColor.Yellow));
        var manager = new FlatpakManager();
        var result = manager.UpdateApp(Package);
        console.WriteLine(Colorize(result, ConsoleColor.Yellow));
    }

    public override ValueTask ExecuteUiMode()
    {
        UiFrames.Info("Updating flatpak app...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        var manager = new FlatpakManager();
        var result = manager.UpdateApp(Package);
        UiFrames.Info(result);
        UiFrames.TxFinish(true, "Flatpak update complete.", "Flatpak update failed.");
        return ValueTask.CompletedTask;
    }
}
