using System.CommandLine;
using PackageManager.Alpm;
using Shelly.Cli.Interactions;
using static System.CommandLine.ArgumentArity;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Standard;

public class Mark : GlobalSettingsCommand
{
    private bool Explicit { get; set; }

    private bool Depends { get; set; }

    private string? Package { get; set; }

    public static Command Create()
    {
        var explicitOption = new Option<bool>("--explicit", "-e") { Description = "Mark the package as explicit" };
        var dependsOption = new Option<bool>("--depends", "-d") { Description = "Mark the package as a dependency" };
        var packageOption = new Argument<string?>("package") { Description = "The package to mark", Arity = ZeroOrOne };
        var command = new Command("mark", "Mark a package as explicit or a dependency") { explicitOption, dependsOption, packageOption };
        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Mark
            {
                Explicit = parseResult.GetValue(explicitOption),
                Depends = parseResult.GetValue(dependsOption),
                Package = parseResult.GetValue(packageOption)
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

        if (string.IsNullOrWhiteSpace(Package))
        {
            console.WriteLine(Colorize("Error: No package specified", ConsoleColor.Red));
            return;
        }

        if (Explicit == Depends)
        {
            console.WriteLine(Colorize("Error: Choose exactly one of --explicit or --depends", ConsoleColor.Red));
            return;
        }

        RootElevator.EnsureRootExectuion();

        if (!NoConfirm && !Confirm.Execute("Do you want to proceed with the operation?"))
        {
            console.WriteLine(Colorize("Operation Cancelled.", ConsoleColor.Yellow));
            return;
        }

        using var manager = new AlpmManager();
        manager.Initialize(true);

        var success = Explicit ? manager.MarkPackageAsExplicit(Package) : manager.MarkPackageAsDepend(Package);
        console.WriteLine(success
            ? Colorize("Package marked successfully!", ConsoleColor.Green)
            : Colorize("Error: Marking failed for the package. See messages above.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (string.IsNullOrWhiteSpace(Package))
        {
            UiFrames.Error("No package specified.");
            return;
        }

        if (Explicit == Depends)
        {
            UiFrames.Error("Choose exactly one of --explicit or --depends.");
            return;
        }

        using var manager = new AlpmManager();
        manager.Initialize(true);

        UiFrames.TxStart("Marking package...");

        var success = Explicit ? manager.MarkPackageAsExplicit(Package) : manager.MarkPackageAsDepend(Package);

        UiFrames.TxFinish(success, "Package marked successfully!", "Marking failed for the package.");
    }
}