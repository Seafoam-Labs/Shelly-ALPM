using System.CommandLine;
using PackageManager.Flatpak;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class InstallBundle : GlobalSettingsCommand
{
    private string BundlePath { get; set; } = string.Empty;
    private bool SystemWide { get; set; }

    public static Command Create()
    {
        var bundlePath = new Argument<string>("BundlePath") { Description = "Path to the .flatpak bundle file" };
        var system = new Option<bool>("--system", "-s") { Description = "Install system-wide", DefaultValueFactory = _ => true };

        var command = new Command("install-bundle", "Installs flatpak app from bundle file")
        {
            bundlePath, system
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new InstallBundle
            {
                BundlePath = parseResult.GetValue(bundlePath) ?? string.Empty,
                SystemWide = parseResult.GetValue(system)
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override ValueTask ExecuteAsync(IShellyConsole console)
    {
        console.WriteLine(Colorize("Installing flatpak bundle...", ConsoleColor.Yellow));
        var manager = new FlatpakManager();
        manager.FlatpakEvent += (_, args) => console.WriteLine(Colorize(args.Message, ConsoleColor.Yellow));
        manager.InstallAppFromBundle(BundlePath, SystemWide);
        return ValueTask.CompletedTask;
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;
}
