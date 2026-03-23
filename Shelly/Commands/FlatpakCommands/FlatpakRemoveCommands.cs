using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakRemoveCommands
{
    internal static int RemoveUiMode(string package, bool removeUnused)
    {
        try
        {
            var manager = new FlatpakManager();
            var result = manager.UninstallApp(package, removeUnused);
            Console.Error.WriteLine(result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Removal failed: {ex.Message}");
            return 1;
        }
    }
    internal static int RemoveConsoleMode(string package, bool removeUnused)
    {
        try
        {
            var manager = new FlatpakManager();
            var result = manager.UninstallApp(package, removeUnused);
            Console.WriteLine(result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Removal failed: {ex.Message}");
            return 1;
        }
    }
}
