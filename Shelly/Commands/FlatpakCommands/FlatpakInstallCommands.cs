using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakInstallCommands
{
    internal static int InstallUiMode(string package, bool isUser, string? remote, string branch)
    {
        try
        {
            Console.Error.WriteLine("Installing flatpak app...");
            var manager = new FlatpakManager();
            var result = manager.InstallApp(package, remote, isUser, branch);
            Console.Error.WriteLine("Installed: " + result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Installation failed: {ex.Message}");
            return 1;
        }
    }
    internal static int InstallConsoleMode(string package, bool isUser, string? remote, string branch)
    {
        try
        {
            Console.WriteLine("Installing flatpak app...");
            var manager = new FlatpakManager();
            var result = manager.InstallApp(package, remote, isUser, branch);
            Console.WriteLine("Installed: " + result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Installation failed: {ex.Message}");
            return 1;
        }
    }
}
