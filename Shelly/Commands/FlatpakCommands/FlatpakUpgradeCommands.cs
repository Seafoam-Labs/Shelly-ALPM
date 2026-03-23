using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakUpgradeCommands
{
    internal static int UpgradeUiMode()
    {
        try
        {
            Console.Error.WriteLine("Updating all flatpak apps...");
            var manager = new FlatpakManager();
            var result = manager.UpdateAllFlatpak();
            Console.Error.WriteLine(result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Upgrade failed: {ex.Message}");
            return 1;
        }
    }
    internal static int UpgradeConsoleMode()
    {
        try
        {
            Console.WriteLine("Updating all flatpak apps...");
            var manager = new FlatpakManager();
            var result = manager.UpdateAllFlatpak();
            Console.WriteLine(result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Upgrade failed: {ex.Message}");
            return 1;
        }
    }
}
