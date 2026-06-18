using System.CommandLine;
using System.Text.Json;
using PackageManager.Alpm;
using Shelly.Cli.Interactions;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Standard;

public class PurifyPackages : GlobalSettingsCommand
{
    private bool DryRun { get; set; }

    private bool Orphans { get; set; }

    public static Command Create()
    {
        var dryRun = new Option<bool>("--dry-run", "-d")
            { Description = "Show what would be removed without removing it." };
        var orphans = new Option<bool>("--orphans", "-o") { Description = "Also remove orphaned dependencies." };
        var command = new Command("purify", "Remove corrupted/orphaned packages") { dryRun, orphans };
        command.SetAction(async (parseResult, _) =>
        {
            var instance = new PurifyPackages
            {
                DryRun = parseResult.GetValue(dryRun),
                Orphans = parseResult.GetValue(orphans)
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


        if (!NoConfirm && !DryRun && !Confirm.Execute("Do you want to proceed with the operation?"))
        {
            console.WriteLine(Colorize("Operation Cancelled.", ConsoleColor.Yellow));
            return;
        }

        using var manager = new AlpmManager();
        manager.Initialize(true);

        var results = await manager.PurifyPackages(DryRun, Orphans);

        if (results.Count == 0)
        {
            console.WriteLine(Colorize("No packages found to purify!", ConsoleColor.Green));
            return;
        }

        if (JsonOutput)
        {
            console.WriteLine(JsonSerializer.Serialize(results, ShellyCliJsonContext.Default.ListString));
            return;
        }

        console.WriteLine(Colorize(DryRun ? "Running would remove:" : "Removed:", ConsoleColor.Green));
        var table = BasicTable.Execute(["Package"], results, p => p);
        console.WriteLine(table);
    }

    public override async ValueTask ExecuteUiMode()
    {
        using var manager = new AlpmManager();
        manager.Initialize(true);

        UiFrames.TxStart("Purifying packages...");

        var results = await manager.PurifyPackages(DryRun, Orphans);

        UiFrames.Frame(results);
        UiFrames.TxDone(DryRun ? "Dry run complete." : "Packages purified.");
    }
}