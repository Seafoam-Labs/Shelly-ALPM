using System.Diagnostics.CodeAnalysis;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Keyring;

public class KeyringListCommand : Command
{
    public override int Execute([NotNull] CommandContext context)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeList();
        }

        RootElevator.EnsureRootExectuion();
        AnsiConsole.MarkupLine("[yellow]Listing keys in keyring...[/]");
        return PacmanKeyRunner.Run("--list-keys");
    }

    private static int HandleUiModeList()
    {
        UiFrames.Info("Listing keys in keyring...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        var result = PacmanKeyRunner.Run("--list-keys");
        UiFrames.TxFinish(result == 0, "Keys listed.", "Failed to list keys.");
        return result;
    }
}
