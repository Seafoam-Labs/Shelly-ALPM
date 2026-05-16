using PackageManager.Flatpak;
using PackageManager.Wire;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlathubGetRemote : Command<FlatpakListRemoteAppStreamSettings>
{
    public override int Execute(CommandContext context, FlatpakListRemoteAppStreamSettings settings)
    {
        var result = settings.AppStreamName == "all"
            ? new FlatpakManager().GetAvailableAppsFromAppstreamJson("all", getAll: true)
            : new FlatpakManager().GetAvailableAppsFromAppstreamJson(settings.AppStreamName);

        if (Program.IsUiMode)
        {
            JsonPackFrame.WriteToStdout(result);
        }
        else
        {
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(result);
            writer.Flush();
        }

        return 0;
    }
}