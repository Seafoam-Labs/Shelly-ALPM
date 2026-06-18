using System.CommandLine;
using PackageManager.Flatpak;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class Remove : GlobalSettingsCommand
{
    private string Package { get; set; } = string.Empty;
    private bool RemoveUnused { get; set; }
    private bool RemoveConfig { get; set; }

    public static Command Create()
    {
        var package = new Argument<string>("package") { Description = "Flatpak application ID (e.g., com.spotify.Client)" };
        var removeUnused = new Option<bool>("--remove-unused", "-r") { Description = "Remove unused dependencies after uninstalling" };
        var removeConfig = new Option<bool>("--config", "-c") { Description = "Removes flatpak configuration for removed app" };

        var command = new Command("uninstall", "Remove flatpak app")
        {
            package, removeUnused, removeConfig
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Remove
            {
                Package = parseResult.GetValue(package) ?? string.Empty,
                RemoveUnused = parseResult.GetValue(removeUnused),
                RemoveConfig = parseResult.GetValue(removeConfig)
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

        var manager = new FlatpakManager();
        manager.FlatpakEvent += (_, args) => console.WriteLine(Colorize(args.Message, ConsoleColor.Yellow));
        var dto = manager.FindAppByNameOrId(Package);
        manager.UninstallApp(Package, RemoveUnused);

        if (RemoveConfig)
        {
            console.WriteLine(RemoveLocalConfig(dto.Id) == 0
                ? Colorize("Local flatpak config removed", ConsoleColor.Green)
                : Colorize("Failed to remove local flatpak config", ConsoleColor.Yellow));
        }
    }

    public override ValueTask ExecuteUiMode()
    {
        UiFrames.Info("Removing flatpak app...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        var manager = new FlatpakManager();
        manager.FlatpakEvent += (_, args) => UiFrames.Info(args.Message);
        manager.UninstallApp(Package, RemoveUnused);
        UiFrames.TxFinish(true, "Flatpak removal complete.", "Flatpak removal failed.");
        return ValueTask.CompletedTask;
    }

    private static int RemoveLocalConfig(string appId)
    {
        if (string.IsNullOrWhiteSpace(appId))
        {
            return 1;
        }

        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".var", "app", appId);

        if (Directory.Exists(path))
            Directory.Delete(path, recursive: true);

        return 0;
    }
}
