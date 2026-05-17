using System.Text.Json;
using PackageManager.Flatpak;
using PackageManager.Wire;
using Shelly.Utilities;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class GetAppRemoteInfo : Command<FlatpakInstallSize>
{
    public override int Execute(CommandContext context, FlatpakInstallSize settings)
    {
        var manager = new FlatpakManager();
        var result = manager.GetRemoteSize(settings.Remote, settings.Name, "", settings.Branch);

        if (settings.Json)
        {
            if (Program.IsUiMode)
            {
                JsonPackFrame.WriteToStdout(result);
            }
            else
            {
                var json = JsonSerializer.Serialize(result, AppstreamJsonContext.Default.FlatpakRemoteRefInfo);
                using var stdout = Console.OpenStandardOutput();
                using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
                writer.WriteLine(json);
                writer.Flush();
            }
        }
        else
        {
            Console.Write("Download Size:" + SizeHelper.FormatSize((long)result.DownloadSize) +
                          " Install Size:" + SizeHelper.FormatSize((long)result.InstalledSize));
        }

        return 0;
    }
}

public class FlatpakInstallSize : CommandSettings
{
    [CommandArgument(0, "<remote>")] public string Remote { get; set; } = "";

    [CommandArgument(1, "<id>")] public string Name { get; set; } = "";

    [CommandArgument(2, "<branch>")] public string Branch { get; set; } = "";

    [CommandOption("-j|--json <branch>")] public bool Json { get; set; } = false;
}