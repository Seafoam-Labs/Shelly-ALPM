using System.CommandLine;
using PackageManager.Flatpak;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class InstallRefFile : GlobalSettingsCommand
{
    private string RefFilePath { get; set; } = string.Empty;
    private bool SystemWide { get; set; }

    public static Command Create()
    {
        var refFilePath = new Argument<string>("RefFilePath") { Description = "Path to the ref file" };
        var system = new Option<bool>("--system", "-s") { Description = "Install system-wide", DefaultValueFactory = _ => true };

        var command = new Command("install-ref-file", "Installs flatpak app from ref file")
        {
            refFilePath, system
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new InstallRefFile
            {
                RefFilePath = parseResult.GetValue(refFilePath) ?? string.Empty,
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
        console.WriteLine(Colorize("Installing flatpak app...", ConsoleColor.Yellow));
        var manager = new FlatpakManager();
        manager.FlatpakEvent += (_, args) => console.WriteLine(Colorize(args.Message, ConsoleColor.Yellow));
        manager.InstallAppFromRef(RefFilePath, SystemWide);
        return ValueTask.CompletedTask;
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;
}
