using System.CommandLine;
using PackageManager.Alpm;
using PackageManager.Aur;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;

namespace Shelly.Cli.Commands.Aur;

public class Remove : GlobalSettingsCommand
{
    private bool Cascade { get; set; }

    private bool OptDeps { get; set; }

    private bool Ripple { get; set; }

    private string[] Package { get; set; } = Array.Empty<string>();

    public static Command Create()
    {
        var cascade = new Option<bool>("--cascade", "-c")
        {
            Description = "Removes all things the removed package(s) are dependent on that have no other uses (default: true)",
            DefaultValueFactory = _ => true
        };
        var optDeps = new Option<bool>("--opt-deps", "-o")
            { Description = "Removes optional dependencies installed with the package, that don't depend on other packages" };
        var ripple = new Option<bool>("--ripple", "-i")
            { Description = "Removes packages that depend on the package being removed" };
        var package = new Argument<string[]>("packages")
            { Description = "One or more AUR package names to operate on (space-separated)", Arity = ArgumentArity.ZeroOrMore };

        var command = new Command("remove", "Remove AUR packages")
        {
            cascade, optDeps, ripple, package
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Remove
            {
                Cascade = parseResult.GetValue(cascade),
                OptDeps = parseResult.GetValue(optDeps),
                Ripple = parseResult.GetValue(ripple),
                Package = parseResult.GetValue(package) ?? Array.Empty<string>()
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    private AlpmTransFlag BuildFlags()
    {
        var flags = AlpmTransFlag.None;
        if (Cascade)
            flags |= AlpmTransFlag.NoSave | AlpmTransFlag.Recurse;
        else if (Ripple)
            flags |= AlpmTransFlag.Cascade;
        return flags;
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

        console.WriteLine(AnsiUtilities.Colorize(
            $"Removing AUR packages: {string.Join(", ", packageList)}", ConsoleColor.Yellow));

        if (!NoConfirm && !Confirm.Execute("Do you want to proceed?"))
        {
            console.WriteLine(AnsiUtilities.Colorize("Operation cancelled.", ConsoleColor.Yellow));
            return;
        }

        using var manager = new AurPackageManager();
        await manager.Initialize(root: true);

        var result = await AurSinglePaneOutput.Output(console, manager,
            m => m.RemovePackages(packageList, BuildFlags(), OptDeps), NoConfirm);

        console.WriteLine(result
            ? AnsiUtilities.Colorize("Removal complete.", ConsoleColor.Green)
            : AnsiUtilities.Colorize("Removal failed. See errors above.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Package.Length == 0)
        {
            UiFrames.Error("No packages specified");
            return;
        }

        using var manager = new AurPackageManager();
        await manager.Initialize(root: true);

        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);
        manager.PkgbuildDiffRequest += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);

        var packageList = Package.ToList();
        UiFrames.TxStart($"Removing AUR packages: {string.Join(", ", packageList)}");

        var ok = await UiModeOutput.Run(manager, m => m.RemovePackages(packageList, BuildFlags(), OptDeps));
        UiFrames.TxFinish(ok, "Removal complete.", "Removal failed.");
    }
}
