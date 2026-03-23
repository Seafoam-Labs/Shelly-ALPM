using System.Text.Json;
using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakGetAppRemoteInfoCommands
{
    internal static int GetAppRemoteInfoUiMode(string remote, string id, string branch, bool json)
    {
        var manager = new FlatpakManager();
        var result = manager.GetRemoteSize(remote, id, "", branch);
        if (json)
        {
            var jsonStr = JsonSerializer.Serialize(result, AppstreamJsonContext.Default.FlatpakRemoteRefInfo);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(jsonStr);
            writer.Flush();
        }
        else
        {
            Console.Error.Write("Download Size:" + FormatSize(result.DownloadSize) +
                                " Install Size:" + FormatSize(result.InstalledSize));
        }
        return 0;
    }
    internal static int GetAppRemoteInfoConsoleMode(string remote, string id, string branch, bool json)
    {
        var manager = new FlatpakManager();
        var result = manager.GetRemoteSize(remote, id, "", branch);
        if (json)
        {
            var jsonStr = JsonSerializer.Serialize(result, AppstreamJsonContext.Default.FlatpakRemoteRefInfo);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(jsonStr);
            writer.Flush();
        }
        else
        {
            Console.Write("Download Size:" + FormatSize(result.DownloadSize) +
                          " Install Size:" + FormatSize(result.InstalledSize));
        }
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
