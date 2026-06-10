using System.Diagnostics.CodeAnalysis;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Keyring;

public class KeyringInitCommand : Command
{
    public override int Execute([NotNull] CommandContext context)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeInit();
        }

        RootElevator.EnsureRootExectuion();
        AnsiConsole.MarkupLine("[yellow]Initializing pacman keyring...[/]");
        var result = PacmanKeyRunner.Run("--init");
        if (result == 0)
        {
            AnsiConsole.MarkupLine("[green]Keyring initialized successfully![/]");
        }
        else
        {
            AnsiConsole.MarkupLine("[red]Failed to initialize keyring.[/]");
        }

        return result;
    }

    private static int HandleUiModeInit()
    {
        UiFrames.Info("Initializing pacman keyring...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        var result = PacmanKeyRunner.Run("--init");
        UiFrames.TxFinish(result == 0, "Keyring initialized successfully!", "Failed to initialize keyring.");
        return result;
    }
}
