using System.Diagnostics.CodeAnalysis;
using System.Text.Json;
using PackageManager.Flatpak;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class GetAppRemoteInfo : Command<FlatpakInstallSize>
{
    public override int Execute([NotNull] CommandContext context, [NotNull] FlatpakInstallSize settings)
    {
        var manager = new FlatpakManager();
        var result = manager.GetRemoteSize(settings.Remote, settings.Name, "", settings.Branch);

        if (settings.Json)
        {
            var json = JsonSerializer.Serialize(result, AppstreamJsonContext.Default.FlatpakRemoteRefInfo);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new System.IO.StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(json);
            writer.Flush();
        }
        else
            Console.Write("Download Size:" + FormatSize(result.DownloadSize) +
                          " Install Size:" + FormatSize(result.InstalledSize));

        return 0;
    }

    private static string FormatSize(ulong bytes)
    {
        string[] suffixes = ["B", "KB", "MB", "GB", "TB"];
        var i = 0;
        double dblSByte = bytes;
        while (i < suffixes.Length && bytes >= 1024)
        {
            dblSByte = bytes / 1024.0;
            i++;
            bytes /= 1024;
        }

        return $"{dblSByte:0.##} {suffixes[i]}";
    }
}

public class FlatpakInstallSize : CommandSettings
{
    [CommandArgument(0, "<remote>")] public string Remote { get; set; } = "";

    [CommandArgument(1, "<id>")] public string Name { get; set; } = "";

    [CommandArgument(2, "<branch>")] public string Branch { get; set; } = "";

    [CommandOption("-j|--json <branch>")] public bool Json { get; set; } = false;
}