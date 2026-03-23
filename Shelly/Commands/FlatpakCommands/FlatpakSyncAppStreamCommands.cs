using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakSyncAppStreamCommands
{
    internal static int SyncAppStreamUiMode()
    {
        var (success, message) = new FlatpakManager().UpdateAppstream();
        Console.Error.WriteLine(message);
        return success ? 0 : 1;
    }
    internal static int SyncAppStreamConsoleMode()
    {
        var (success, message) = new FlatpakManager().UpdateAppstream();
        Console.WriteLine(message);
        return success ? 0 : 1;
    }
}
