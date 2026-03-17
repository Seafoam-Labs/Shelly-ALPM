using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakAddRemote :  Command<FlatpakRemoteSettings>
{
    public override int Execute([NotNull] CommandContext context,[NotNull] FlatpakRemoteSettings settings)
    {
        
        var manager = new FlatpakManager();

        AnsiConsole.MarkupLine($"[blue]Adding remote {settings.RemoteName} [/]");
        
        var remotes = manager.AddRemote(settings.RemoteName, settings.RemoteUrl, settings.SystemWide, settings.GpgVerify);
        
        AnsiConsole.MarkupLine($"{remotes}");
        
        return 0;
    }
}
