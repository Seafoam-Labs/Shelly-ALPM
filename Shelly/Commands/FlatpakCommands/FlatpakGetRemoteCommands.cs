using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakGetRemoteCommands
{
    internal static int GetRemote(string appStreamName)
    {
        var result = appStreamName == "all"
            ? new FlatpakManager().GetAvailableAppsFromAppstreamJson("all", getAll: true)
            : new FlatpakManager().GetAvailableAppsFromAppstreamJson(appStreamName);
        using var stdout = Console.OpenStandardOutput();
        using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
        writer.WriteLine(result);
        writer.Flush();
        return 0;
    }
}
