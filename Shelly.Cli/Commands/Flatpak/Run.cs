using System.CommandLine;
using PackageManager.Flatpak;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class Run : GlobalSettingsCommand
{
    private string Package { get; set; } = string.Empty;

    public static Command Create()
    {
        var package = new Argument<string>("package") { Description = "Flatpak application ID (e.g., com.spotify.Client)" };

        var command = new Command("run", "Run flatpak app")
        {
            package
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Run
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

        console.WriteLine(Colorize("Running selected flatpak app...", ConsoleColor.Yellow));
        var result = new FlatpakManager().LaunchApp(Package);
        console.WriteLine(result
            ? Colorize("App launched successfully", ConsoleColor.Green)
            : Colorize("Failed to launch app", ConsoleColor.Red));
    }

    public override ValueTask ExecuteUiMode()
    {
        UiFrames.Info("Running selected flatpak app...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        var result = new FlatpakManager().LaunchApp(Package);
        UiFrames.TxFinish(result, "App launched successfully", "Failed to launch app");
        return ValueTask.CompletedTask;
    }
}
