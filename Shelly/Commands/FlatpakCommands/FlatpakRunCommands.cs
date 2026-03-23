using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakRunCommands
{
    internal static int RunUiMode(string package)
    {
        Console.Error.WriteLine("Running selected flatpak app...");
        var result = new FlatpakManager().LaunchApp(package);
        if (result)
        {
            Console.Error.WriteLine("App launched successfully");
            return 0;
        }
        Console.Error.WriteLine("Failed to launch app");
        return 1;
    }
    internal static int RunConsoleMode(string package)
    {
        Console.WriteLine("Running selected flatpak app...");
        var result = new FlatpakManager().LaunchApp(package);
        if (result)
        {
            Console.WriteLine("App launched successfully");
            return 0;
        }
        Console.WriteLine("Failed to launch app");
        return 1;
    }
}
