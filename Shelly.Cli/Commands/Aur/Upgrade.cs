using System.CommandLine;
using PackageManager.Aur;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using Shelly.Utilities;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.Aur;

public class Upgrade : GlobalSettingsCommand
{
    private static readonly Option<bool> CheckOption =
        new("--check") { Description = "Run the check() function during AUR package builds (disabled by default)" };

    private static readonly Option<bool> SinglePaneOption =
        new("--singlepane") { Description = "Render output as a single pacman-style linear stream" };

    public bool Check { get; set; }

    public static Command Create()
    {
        var command = new Command("upgrade", "Upgrade all out-of-date AUR packages")
        {
            CheckOption,
            SinglePaneOption
        };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new Upgrade();
            GlobalOptions.Apply(instance, parseResult);
            instance.Check = parseResult.GetValue(CheckOption);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        var ansi = AnsiUtilities.SupportsAnsi;
        string Color(string text, ConsoleColor color) => ansi ? text.Pastel(color) : text;

        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        RootElevator.EnsureRootExectuion();

        using var manager = new AurPackageManager();
        await manager.Initialize(true, noCheck: !Check);

        var updates = await manager.GetPackagesNeedingUpdate();
        if (updates.Count == 0)
        {
            console.WriteLine(Color("All AUR packages are up to date.", ConsoleColor.Green));
            return;
        }

        console.WriteLine(Color($"{updates.Count} AUR packages need updates:", ConsoleColor.Yellow));
        foreach (var pkg in updates)
            console.WriteLine($"  {pkg.Name}: {pkg.Version} -> {pkg.NewVersion}");

        if (!NoConfirm && !Confirm.Execute("Proceed with upgrade?", false))
        {
            console.WriteLine(Color("Upgrade cancelled.", ConsoleColor.Red));
            return;
        }

        var packageNames = updates.Select(u => u.Name).ToList();
        var result = await AurSinglePaneOutput.Output(
            console, manager, m => m.UpdatePackages(packageNames), NoConfirm);

        console.WriteLine(result
            ? Color("Upgrade complete.", ConsoleColor.Green)
            : Color("Upgrade failed. See errors above.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        using var manager = new AurPackageManager();
        await manager.Initialize(true, noCheck: !Check);

        var updates = await manager.GetPackagesNeedingUpdate();
        if (updates.Count == 0)
        {
            UiFrames.Info("AUR Packages are up to date!");
            return;
        }

        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);
        manager.PkgbuildDiffRequest += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);

        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            AlpmEvents.AurDownloadStart,
            $"{updates.Count} AUR packages need updates"));

        var packageNames = updates.Select(u => u.Name).ToList();
        var ok = await UiModeOutput.Run(manager, m => m.UpdatePackages(packageNames));

        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            ok ? AlpmEvents.AurPackageCompleted : AlpmEvents.AurPackageFailed,
            ok ? "Upgrade complete." : "Upgrade failed."));
    }
}
