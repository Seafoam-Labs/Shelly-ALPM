using System.Reflection;
namespace Shelly.Commands.StandardCommands;

internal static class VersionCommands
{
    internal static int ShowVersion(bool uiMode)
    {
        var version = Assembly.GetEntryAssembly()?.GetName().Version?.ToString() ?? "unknown";
        if (uiMode)
            Console.Error.WriteLine($"Shelly v{version}");
        else
            Console.WriteLine($"Shelly v{version}");
        return 0;
    }
}
