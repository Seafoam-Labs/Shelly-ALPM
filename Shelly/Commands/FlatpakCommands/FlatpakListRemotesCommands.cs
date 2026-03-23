using System.Text.Json;
using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakListRemotesCommands
{
    internal static int ListRemotesUiMode(bool json)
    {
        var manager = new FlatpakManager();
        var remotes = manager.ListRemotesWithDetails();
        if (json)
        {
            var jsonStr = JsonSerializer.Serialize(remotes, ShellyJsonContext.Default.ListFlatpakRemoteDto);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(jsonStr);
            writer.Flush();
            return 0;
        }
        foreach (var remote in remotes)
        {
            Console.WriteLine($"{remote.Name} ({remote.Scope})");
        }
        return 0;
    }
    internal static int ListRemotesConsoleMode(bool json)
    {
        var manager = new FlatpakManager();
        var remotes = manager.ListRemotesWithDetails();
        if (json)
        {
            var jsonStr = JsonSerializer.Serialize(remotes, ShellyJsonContext.Default.ListFlatpakRemoteDto);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(jsonStr);
            writer.Flush();
            return 0;
        }
        Console.WriteLine("Remotes:");
        foreach (var remote in remotes)
        {
            Console.WriteLine($"  {remote.Name} ({remote.Scope})");
        }
        return 0;
    }
}
