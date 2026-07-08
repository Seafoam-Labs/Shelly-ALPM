using System.CommandLine;
using PackageManager.Flatpak;
using PackageManager.Flatpak.Enums;
using Shelly.Cli.Outputs;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class InstallBundle : GlobalSettingsCommand
{
    /// <summary>
    /// Resolved no-confirm for flatpakinstall actions: per-action flag OR global flag.
    /// </summary>
    private bool EffectiveNoConfirm => NoConfirmFlatpakInstall ?? false || NoConfirm;

    private string BundlePath { get; set; } = string.Empty;
    private bool SystemWide { get; set; }

    public static Command Create()
    {
        var bundlePath = new Argument<string>("BundlePath") { Description = "Path to the .flatpak bundle file" };
        var system = new Option<bool>("--system", "-s")
            { Description = "Install system-wide", DefaultValueFactory = _ => true };

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
            await instance.ExecuteAsync(ShellyConsoleFactory.Create());
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

        console.WriteLine(Colorize("Installing flatpak bundle...", ConsoleColor.Yellow));
        var manager = new FlatpakManager();
        await FlatpakSinglePaneOutput.Output(console, manager,
            x => x.InstallAppFromBundle(BundlePath, SystemWide ? InstallLevel.System : InstallLevel.User), EffectiveNoConfirm);
    }

    public override async ValueTask ExecuteUiMode()
    {
        UiFrames.TxStart("Installing flatpak app...");
        var manager = new FlatpakManager();
        await UiModeOutput.Run(manager,
            x => x.InstallAppFromBundle(BundlePath, SystemWide ? InstallLevel.System : InstallLevel.User));
        UiFrames.TxDone("Flatpak install complete.");
    }
}