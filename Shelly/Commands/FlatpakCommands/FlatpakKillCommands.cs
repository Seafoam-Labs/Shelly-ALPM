using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakKillCommands
{
    internal static int KillUiMode(string package)
    {
        Console.Error.WriteLine("Killing selected flatpak app...");
        var result = new FlatpakManager().KillApp(package);
        Console.Error.WriteLine(result);
        return 0;
    }
    internal static int KillConsoleMode(string package)
    {
        Console.WriteLine("Killing selected flatpak app...");
        var result = new FlatpakManager().KillApp(package);
        Console.WriteLine(result);
        return 0;
    }
}
