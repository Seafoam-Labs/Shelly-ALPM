using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakUpdateCommands
{
    internal static int UpdateUiMode(string package)
    {
        try
        {
            Console.Error.WriteLine("Updating flatpak app...");
            var manager = new FlatpakManager();
            var result = manager.UpdateApp(package);
            Console.Error.WriteLine(result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Update failed: {ex.Message}");
            return 1;
        }
    }
    internal static int UpdateConsoleMode(string package)
    {
        try
        {
            Console.WriteLine("Updating flatpak app...");
            var manager = new FlatpakManager();
            var result = manager.UpdateApp(package);
            Console.WriteLine(result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Update failed: {ex.Message}");
            return 1;
        }
    }
}
