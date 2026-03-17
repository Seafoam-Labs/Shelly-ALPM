using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakRemoveRemote : Command<FlatpakRemoveRemoteSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakRemoveRemoteSettings settings)
    {
        var manager = new FlatpakManager();

        AnsiConsole.MarkupLine($"[red]Removing remote {settings.RemoteName} [/]");

        var remotes = manager.RemoveRemote(settings.RemoteName, settings.SystemWide);

        AnsiConsole.MarkupLine($"{remotes}");

        return 0;
    }
}