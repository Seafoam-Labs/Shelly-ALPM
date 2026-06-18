using System.CommandLine;
using PackageManager.Alpm;
using Shelly.Cli.Outputs;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Standard;

public class Sync : GlobalSettingsCommand
{
    private bool Force { get; set; }

    public static Command Create()
    {
        var force = new Option<bool>("--force", "-f") { Description = "Force a sync" };
        var command = new Command("sync", "Syncs the system with the current state") { force };
        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Sync
            {
                Force = parseResult.GetValue(force)
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

        console.WriteLine(Colorize("Initializing ALPM...", ConsoleColor.Yellow));
        using var manager = new AlpmManager();
        manager.Initialize(true);

        console.WriteLine(Colorize("Synchronizing package databases...", ConsoleColor.Yellow));

        var result = await StandardSinglePaneOutput.Output(
            console, manager, m =>
            {
                m.Sync(Force);
                return Task.FromResult(true);
            }, NoConfirm);

        console.WriteLine(result
            ? Colorize("Package databases synchronized successfully!", ConsoleColor.Green)
            : Colorize("Sync failed. See errors above.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        using var manager = new AlpmManager();
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);
        manager.Initialize(true);

        UiFrames.TxStart("Synchronizing package databases...");

        var ok = await UiModeOutput.Run(manager, m =>
        {
            m.Sync(Force);
            return Task.CompletedTask;
        });

        UiFrames.TxFinish(ok, "Package databases synchronized successfully!", "Sync failed.");
    }
}