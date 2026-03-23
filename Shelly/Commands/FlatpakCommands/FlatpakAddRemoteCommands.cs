using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakAddRemoteCommands
{
    internal static int AddRemoteUiMode(string remoteName, string remoteUrl, bool systemWide, bool gpgVerify)
    {
        try
        {
            Console.Error.WriteLine($"Adding remote {remoteName}...");
            var manager = new FlatpakManager();
            var result = manager.AddRemote(remoteName, remoteUrl, systemWide, gpgVerify);
            Console.Error.WriteLine(result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to add remote: {ex.Message}");
            return 1;
        }
    }
    internal static int AddRemoteConsoleMode(string remoteName, string remoteUrl, bool systemWide, bool gpgVerify)
    {
        try
        {
            Console.WriteLine($"Adding remote {remoteName}...");
            var manager = new FlatpakManager();
            var result = manager.AddRemote(remoteName, remoteUrl, systemWide, gpgVerify);
            Console.WriteLine(result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to add remote: {ex.Message}");
            return 1;
        }
    }
}
