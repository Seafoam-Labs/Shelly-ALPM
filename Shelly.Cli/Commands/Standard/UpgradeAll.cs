using System.CommandLine;
using Shelly.Cli.Interactions;
using static Shelly.Cli.Interactions.AnsiUtilities;
using AurUpgrade = Shelly.Cli.Commands.Aur.Upgrade;
using FlatpakUpgrade = Shelly.Cli.Commands.Flatpak.Upgrade;
using AppImageUpgrade = Shelly.Cli.Commands.AppImage.AppImageUpgrade;

namespace Shelly.Cli.Commands.Standard;

public class UpgradeAll : GlobalSettingsCommand
{
    private static readonly Option<bool> NoRepoOption =
        new("--no-repo") { Description = "Skip the standard repository (ALPM) upgrade" };

    private static readonly Option<bool> NoAurOption =
        new("--no-aur") { Description = "Skip the AUR upgrade" };

    private static readonly Option<bool> NoFlatpakOption =
        new("--no-flatpak") { Description = "Skip the Flatpak upgrade" };

    private static readonly Option<bool> NoAppImageOption =
        new("--no-appimage") { Description = "Skip the AppImage upgrade" };

    public bool NoRepo { get; set; }

    public bool NoAur { get; set; }

    public bool NoFlatpak { get; set; }

    public bool NoAppImage { get; set; }

    public static Command Create()
    {
        var command = new Command("upgrade-all",
            "Upgrade all packages from every source (repo, AUR, Flatpak, AppImage)")
        {
            NoRepoOption,
            NoAurOption,
            NoFlatpakOption,
            NoAppImageOption
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new UpgradeAll
            {
                NoRepo = parseResult.GetValue(NoRepoOption),
                NoAur = parseResult.GetValue(NoAurOption),
                NoFlatpak = parseResult.GetValue(NoFlatpakOption),
                NoAppImage = parseResult.GetValue(NoAppImageOption)
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

        RootElevator.EnsureRootExectuion();

        if (!NoRepo)
            await RunChild(new Upgrade(), console);
        if (!NoAur)
            await RunChild(new AurUpgrade(), console);
        if (!NoFlatpak)
            await RunChild(new FlatpakUpgrade(), console);
        if (!NoAppImage)
            await RunChild(new AppImageUpgrade(), console);

        console.WriteLine(Colorize("All upgrades complete.", ConsoleColor.Green));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (!NoRepo)
            await RunChild(new Upgrade(), null);
        if (!NoAur)
            await RunChild(new AurUpgrade(), null);
        if (!NoFlatpak)
            await RunChild(new FlatpakUpgrade(), null);
        if (!NoAppImage)
            await RunChild(new AppImageUpgrade(), null);
    }

    private async ValueTask RunChild(GlobalSettingsCommand child, IShellyConsole? console)
    {
        child.NoConfirm = NoConfirm;
        child.UiMode = UiMode;
        child.JsonOutput = JsonOutput;
        child.Verbose = Verbose;

        try
        {
            if (UiMode)
                await child.ExecuteAsync(new SystemShellyConsole());
            else
                await child.ExecuteAsync(console!);
        }
        catch (Exception ex)
        {
            if (console is not null)
                console.WriteLine(Colorize($"Upgrade step failed: {ex.Message}", ConsoleColor.Red));
            else
                UiFrames.Error($"Upgrade step failed: {ex.Message}");
        }
    }
}
