using System.CommandLine;
using PackageManager.Aur;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;

namespace Shelly.Cli.Commands.Aur;

public class Update : GlobalSettingsCommand
{
    /// <summary>
    /// Resolved no-confirm for aurupgrade actions: per-action flag OR global flag.
    /// </summary>
    private bool EffectiveNoConfirm => NoConfirmAurUpgrade ?? false || NoConfirm;

    private bool Check { get; set; }

    private string[] Package { get; set; } = Array.Empty<string>();

    public static Command Create()
    {
        var check = new Option<bool>("--check")
            { Description = "Run the check() function during AUR package builds (disabled by default)" };
        var package = new Argument<string[]>("packages")
            { Description = "One or more AUR package names to operate on (space-separated)", Arity = ArgumentArity.ZeroOrMore };

        var command = new Command("update", "Rebuild and reinstall specific AUR packages")
        {
            check, package
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Update
            {
                Check = parseResult.GetValue(check),
                Package = parseResult.GetValue(package) ?? Array.Empty<string>()
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

        if (Package.Length == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("No packages specified.", ConsoleColor.Red));
            return;
        }

        RootElevator.EnsureRootExectuion();

        var packageList = Package.ToList();

        if (!EffectiveNoConfirm && !Confirm.Execute($"Proceed with update for {string.Join(", ", packageList)}?", true))
        {
            console.WriteLine(AnsiUtilities.Colorize("Update cancelled.", ConsoleColor.Yellow));
            return;
        }

        using var manager = new AurPackageManager();
        await manager.Initialize(root: true, noCheck: !Check);

        var result = await AurSinglePaneOutput.Output(console, manager,
            m => m.UpdatePackages(packageList), EffectiveNoConfirm);

        console.WriteLine(result
            ? AnsiUtilities.Colorize("Update complete.", ConsoleColor.Green)
            : AnsiUtilities.Colorize("Update failed. See errors above.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Package.Length == 0)
        {
            UiFrames.Error("No packages specified");
            return;
        }

        using var manager = new AurPackageManager();
        await manager.Initialize(root: true, noCheck: !Check);

        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, EffectiveNoConfirm);
        manager.PkgbuildDiffRequest += (_, args) => QuestionHandler.HandleQuestion(args, true, EffectiveNoConfirm);

        var packageList = Package.ToList();
        UiFrames.TxStart($"Updating AUR packages: {string.Join(", ", packageList)}");

        var ok = await UiModeOutput.Run(manager, m => m.UpdatePackages(packageList));
        UiFrames.TxFinish(ok, "Update complete.", "Update failed.");
    }
}
