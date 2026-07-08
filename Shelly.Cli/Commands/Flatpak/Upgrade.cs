using System.CommandLine;
using PackageManager.Flatpak;
using PackageManager.Flatpak.Enums;
using Shelly.Cli.Outputs;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class Upgrade : GlobalSettingsCommand
{
    /// <summary>
    /// Resolved no-confirm for flatpakupgrade actions: per-action flag OR global flag.
    /// </summary>
    private bool EffectiveNoConfirm => NoConfirmFlatpakUpgrade ?? false || NoConfirm;

    public static Command Create()
    {
        var command = new Command("upgrade", "Upgrade all flatpak apps");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Upgrade();
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

        var manager = new FlatpakManager();

        console.WriteLine(Colorize("Updating all flatpak apps...", ConsoleColor.Yellow));

        var packages = FlatpakManager.GetPackagesWithUpdates(true).OrderBy(p => p.Id).ToList();

        if (packages.Count == 0)
        {
            console.WriteLine(Colorize("No flatpak updates!", ConsoleColor.Green));
            return;
        }

        if (packages.Any(x => x.InstallLevel == InstallLevel.User))
        {
            await FlatpakSinglePaneOutput.Output(console, manager,
                x => x.UpdateAllUserFlatpak(), EffectiveNoConfirm);
        }

        if (packages.Any(x => x.InstallLevel == InstallLevel.System))
        {
            await FlatpakSinglePaneOutput.Output(console, manager,
                x => x.UpdateAllSystemFlatpak(), EffectiveNoConfirm);
        }
    }

    public async override ValueTask ExecuteUiMode()
    {
        var manager = new FlatpakManager();

        UiFrames.Info("Updating all flatpak apps...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        await UiModeOutput.Run(manager, m => m.UpdateAllUserFlatpak());

        await UiModeOutput.Run(manager, m => manager.UpdateAllSystemFlatpak());
        UiFrames.TxFinish(true, "Flatpak upgrade complete.", "Flatpak upgrade failed.");
    }
}