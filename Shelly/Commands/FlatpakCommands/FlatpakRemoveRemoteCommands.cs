using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakRemoveRemoteCommands
{
    internal static int RemoveRemoteUiMode(string remoteName, bool systemWide)
    {
        try
        {
            Console.Error.WriteLine($"Removing remote {remoteName}...");
            var manager = new FlatpakManager();
            var result = manager.RemoveRemote(remoteName, systemWide);
            Console.Error.WriteLine(result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to remove remote: {ex.Message}");
            return 1;
        }
    }
    internal static int RemoveRemoteConsoleMode(string remoteName, bool systemWide)
    {
        try
        {
            Console.WriteLine($"Removing remote {remoteName}...");
            var manager = new FlatpakManager();
            var result = manager.RemoveRemote(remoteName, systemWide);
            Console.WriteLine(result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to remove remote: {ex.Message}");
            return 1;
        }
    }
}
