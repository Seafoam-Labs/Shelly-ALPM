using System.Diagnostics.CodeAnalysis;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Keyring;

public class KeyringRecvCommand : Command<KeyringSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] KeyringSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeRecv(settings);
        }

        RootElevator.EnsureRootExectuion();
        if (settings.Keys == null || settings.Keys.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]Error: No key IDs specified[/]");
            return 1;
        }

        var args = "--recv-keys " + string.Join(" ", settings.Keys);
        if (!string.IsNullOrEmpty(settings.Keyserver))
        {
            args += $" --keyserver {settings.Keyserver}";
        }

        AnsiConsole.MarkupLine($"[yellow]Receiving keys: {string.Join(", ", settings.Keys.Select(k => k.EscapeMarkup()))}...[/]");
        var result = PacmanKeyRunner.Run(args);
        if (result == 0)
        {
            AnsiConsole.MarkupLine("[green]Keys received successfully![/]");
        }
        else
        {
            AnsiConsole.MarkupLine("[red]Failed to receive keys.[/]");
        }

        return result;
    }

    private static int HandleUiModeRecv(KeyringSettings settings)
    {
        if (settings.Keys == null || settings.Keys.Length == 0)
        {
            UiFrames.Error("No key IDs specified");
            return 1;
        }

        var args = "--recv-keys " + string.Join(" ", settings.Keys);
        if (!string.IsNullOrEmpty(settings.Keyserver))
        {
            args += $" --keyserver {settings.Keyserver}";
        }

        UiFrames.Info($"Receiving keys: {string.Join(", ", settings.Keys)}...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);
        var result = PacmanKeyRunner.Run(args);
        UiFrames.TxFinish(result == 0, "Keys received successfully!", "Failed to receive keys.");
        return result;
    }
}
