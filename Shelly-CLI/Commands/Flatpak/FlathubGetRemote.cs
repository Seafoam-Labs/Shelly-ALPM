using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlathubGetRemote : Command<FlatpakListRemoteAppStreamSettings>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakListRemoteAppStreamSettings settings)
    {
        var result = settings.AppStreamName == "all" ? new FlatpakManager().GetAvailableAppsFromAppstreamJson("all", getAll: true) : new FlatpakManager().GetAvailableAppsFromAppstreamJson(settings.AppStreamName);
        
        using var stdout = Console.OpenStandardOutput();
        using var writer = new System.IO.StreamWriter(stdout, System.Text.Encoding.UTF8);
        writer.WriteLine(result);
        writer.Flush();
        return 0;
    }
}