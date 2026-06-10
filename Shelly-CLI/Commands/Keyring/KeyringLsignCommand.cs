using System.Diagnostics.CodeAnalysis;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Keyring;

public class KeyringLsignCommand : Command<KeyringSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] KeyringSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeLsign(settings);
        }

        RootElevator.EnsureRootExectuion();
        if (settings.Keys == null || settings.Keys.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]Error: No key IDs specified[/]");
            return 1;
        }

        AnsiConsole.MarkupLine($"[yellow]Locally signing keys: {string.Join(", ", settings.Keys.Select(k => k.EscapeMarkup()))}...[/]");

        foreach (var key in settings.Keys)
        {
            var result = PacmanKeyRunner.Run($"--lsign-key {key}");
            if (result != 0)
            {
                AnsiConsole.MarkupLine($"[red]Failed to sign key: {key.EscapeMarkup()}[/]");
                return result;
            }
        }

        AnsiConsole.MarkupLine("[green]Keys signed successfully![/]");
        return 0;
    }

    private static int HandleUiModeLsign(KeyringSettings settings)
    {
        if (settings.Keys == null || settings.Keys.Length == 0)
        {
            UiFrames.Error("No key IDs specified");
            return 1;
        }

        UiFrames.Info($"Locally signing keys: {string.Join(", ", settings.Keys)}...", Shelly.Utilities.Eventing.AlpmEvents.TransactionStart);

        foreach (var key in settings.Keys)
        {
            var result = PacmanKeyRunner.Run($"--lsign-key {key}");
            if (result != 0)
            {
                UiFrames.Error($"Failed to sign key: {key}");
                UiFrames.TxFinish(false, "Keys signed successfully!", "Failed to sign keys.");
                return result;
            }
        }

        UiFrames.TxFinish(true, "Keys signed successfully!", "Failed to sign keys.");
        return 0;
    }
}
