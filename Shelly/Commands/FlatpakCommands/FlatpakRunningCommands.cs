using PackageManager.Flatpak;
namespace Shelly.Commands.FlatpakCommands;
internal static class FlatpakRunningCommands
{
    internal static int RunningUiMode()
    {
        Console.Error.WriteLine("Currently running flatpak instances on machine...");
        var result = new FlatpakManager().GetRunningInstances();
        if (result.Count > 0)
        {
            foreach (var pkg in result.OrderBy(pkg => pkg.Pid))
            {
                Console.WriteLine($"{pkg.AppId} {pkg.Pid}");
            }
            return 0;
        }
        Console.Error.WriteLine("No instances running");
        return 0;
    }
    internal static int RunningConsoleMode()
    {
        Console.WriteLine("Currently running flatpak instances on machine...");
        var result = new FlatpakManager().GetRunningInstances();
        if (result.Count > 0)
        {
            foreach (var pkg in result.OrderBy(pkg => pkg.Pid))
            {
                Console.WriteLine($"  {pkg.AppId,-40} PID: {pkg.Pid}");
            }
            return 0;
        }
        Console.WriteLine("No instances running");
        return 0;
    }
}
