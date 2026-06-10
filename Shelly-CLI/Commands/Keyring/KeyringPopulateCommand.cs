using System.Diagnostics.CodeAnalysis;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Keyring;

public class KeyringPopulateCommand : Command<KeyringSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] KeyringSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModePopulate(settings);
        }

        RootElevator.EnsureRootExectuion();
        var args = "--populate";
        if (settings.Keys?.Length > 0)
        {
            args += " " + string.Join(" ", settings.Keys);
            AnsiConsole.MarkupLine($"[yellow]Populating keyring with: {string.Join(", ", settings.Keys.Select(k => k.EscapeMarkup()))}...[/]");
        }
        else
        {
            AnsiConsole.MarkupLine("[yellow]Populating keyring with default keys...[/]");
        }

        var result = PacmanKeyRunner.Run(args);
        if (result == 0)
        {
            AnsiConsole.MarkupLine("[green]Keyring populated successfully![/]");
        }
        else
        {
            AnsiConsole.MarkupLine("[red]Failed to populate keyring.[/]");
        }

        return result;
    }

    private static int HandleUiModePopulate(KeyringSettings settings)
    {
        var args = "--populate";
        if (settings.Keys?.Length > 0)
        {
            args += " " + string.Join(" ", settings.Keys);
            UiFrames.Info($"Populating keyring with: {string.Join(", ", settings.Keys)}...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        }
        else
        {
            UiFrames.Info("Populating keyring with default keys...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        }

        var result = PacmanKeyRunner.Run(args);
        UiFrames.TxFinish(result == 0, "Keyring populated successfully!", "Failed to populate keyring.");
        return result;
    }
}
