using System.Diagnostics.CodeAnalysis;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Keyring;

public class KeyringRefreshCommand : Command
{
    public override int Execute([NotNull] CommandContext context)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeRefresh();
        }

        RootElevator.EnsureRootExectuion();
        AnsiConsole.MarkupLine("[yellow]Refreshing keys from keyserver...[/]");
        var result = PacmanKeyRunner.Run("--refresh-keys");
        if (result == 0)
        {
            AnsiConsole.MarkupLine("[green]Keys refreshed successfully![/]");
        }
        else
        {
            AnsiConsole.MarkupLine("[red]Failed to refresh keys.[/]");
        }

        return result;
    }

    private static int HandleUiModeRefresh()
    {
        UiFrames.Info("Refreshing keys from keyserver...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        var result = PacmanKeyRunner.Run("--refresh-keys");
        UiFrames.TxFinish(result == 0, "Keys refreshed successfully!", "Failed to refresh keys.");
        return result;
    }
}
