using System.CommandLine;
using PackageManager.Flatpak;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class Kill : GlobalSettingsCommand
{
    private string Package { get; set; } = string.Empty;

    public static Command Create()
    {
        var package = new Argument<string>("package") { Description = "Flatpak application ID (e.g., com.spotify.Client)" };

        var command = new Command("kill", "Kill running flatpak app")
        {
            package
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Kill
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

        console.WriteLine(Colorize("Killing selected flatpak app...", ConsoleColor.Yellow));
        var manager = new FlatpakManager();
        manager.FlatpakEvent += (_, args) => console.WriteLine(Colorize(args.Message, ConsoleColor.Yellow));
        manager.KillApp(Package);
    }

    public override ValueTask ExecuteUiMode()
    {
        UiFrames.Info("Killing selected flatpak app...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        var manager = new FlatpakManager();
        manager.FlatpakEvent += (_, args) => UiFrames.Info(args.Message);
        manager.KillApp(Package);
        UiFrames.TxFinish(true, "Flatpak app killed.", "Failed to kill flatpak app.");
        return ValueTask.CompletedTask;
    }
}
