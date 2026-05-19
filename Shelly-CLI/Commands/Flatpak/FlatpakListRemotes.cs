using System.Text.Json;
using PackageManager.Flatpak;
using PackageManager.Wire;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakListRemotes : Command<DefaultSettings>
{
    public override int Execute(CommandContext context, DefaultSettings settings)
    {
        var manager = new FlatpakManager();

        var remotes = manager.ListRemotesWithDetails();

        if (settings.JsonOutput)
        {
            if (Program.IsUiMode)
            {
                JsonPackFrame.WriteToStdout(remotes);
            }
            else
            {
                var json = JsonSerializer.Serialize(remotes, ShellyCLIJsonContext.Default.ListFlatpakRemoteDto);
                using var stdout = Console.OpenStandardOutput();
                using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
                writer.WriteLine(json);
                writer.Flush();
            }

            return 0;
        }

        AnsiConsole.MarkupLine($"[blue]Remotes:[/]");
        foreach (var remote in remotes)
        {
            var scopeColor = remote.Scope == "system" ? "green" : "yellow";
            AnsiConsole.MarkupLine($"{remote.Name.EscapeMarkup()} [{scopeColor}]({remote.Scope})[/]");
        }

        return 0;
    }
}