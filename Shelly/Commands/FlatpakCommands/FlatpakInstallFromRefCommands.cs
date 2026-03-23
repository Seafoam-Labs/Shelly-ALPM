using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakInstallFromRefCommands
{
    internal static int InstallFromRefUiMode(string refFilePath, bool systemWide)
    {
        try
        {
            Console.Error.WriteLine("Installing flatpak app from ref file...");
            var result = FlatpakManager.InstallAppFromRef(refFilePath, systemWide);
            Console.Error.WriteLine("Installed: " + result);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Installation failed: {ex.Message}");
            return 1;
        }
    }
    internal static int InstallFromRefConsoleMode(string refFilePath, bool systemWide)
    {
        try
        {
            Console.WriteLine("Installing flatpak app from ref file...");
            var result = FlatpakManager.InstallAppFromRef(refFilePath, systemWide);
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
