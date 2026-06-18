using System.CommandLine;
using PackageManager.Alpm;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using static System.CommandLine.ArgumentArity;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Standard;

public class Update : GlobalSettingsCommand
{
    private string[] Packages { get; set; } = [];

    public static Command Create()
    {
        var package = new Argument<string[]>("packages") { Description = "The packages to update", Arity = ZeroOrMore };

        var command = new Command("update", "Update specific packages") { package };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Update
            {
                Packages = parseResult.GetValue(package) ?? []
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

        if (Packages.Length == 0)
        {
            console.WriteLine(Colorize("Error: No packages specified", ConsoleColor.Red));
            return;
        }

        RootElevator.EnsureRootExectuion();

        console.WriteLine(Colorize($"Packages to update: {string.Join(", ", Packages)}", ConsoleColor.Yellow));

        if (!NoConfirm)
        {
            console.WriteLine(Colorize(
                "WARNING: Updating individual packages is a partial upgrade and is strongly discouraged on Arch Linux.",
                ConsoleColor.Red));
            console.WriteLine(Colorize(
                "Partial upgrades can break your system. The supported way to update is a full system upgrade (shelly upgrade).",
                ConsoleColor.Red));

            if (!Confirm.Execute("Are you absolutely sure you want to continue with this partial upgrade?") ||
                !Confirm.Execute("Do you want to proceed?"))
            {
                console.WriteLine(Colorize("Operation cancelled.", ConsoleColor.Yellow));
                return;
            }
        }

        using var manager = new AlpmManager();
        console.WriteLine(Colorize("Initializing and syncing ALPM...", ConsoleColor.Yellow));
        manager.IntializeWithSync();

        console.WriteLine(Colorize("Updating packages...", ConsoleColor.Yellow));
        var result = await StandardSinglePaneOutput.Output(console, manager, m => m.UpdatePackages(Packages.ToList()), NoConfirm);

        console.WriteLine(result
            ? Colorize("Packages updated successfully!", ConsoleColor.Green)
            : Colorize("Update failed. See errors above.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Packages.Length == 0)
        {
            UiFrames.Error("No packages specified");
            return;
        }

        using var manager = new AlpmManager();
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);
        manager.IntializeWithSync();

        UiFrames.TxStart($"Updating packages: {string.Join(", ", Packages)}");

        var ok = await UiModeOutput.Run(manager, m => m.UpdatePackages(Packages.ToList()));

        UiFrames.TxFinish(ok, "Packages updated successfully!", "Update failed.");
    }
}