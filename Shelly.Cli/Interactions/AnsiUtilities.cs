using Pastel;

namespace Shelly.Cli.Interactions;

internal static class AnsiUtilities
{
    internal static bool SupportsAnsi =>
        !Console.IsOutputRedirected && !Console.IsInputRedirected &&
        Environment.GetEnvironmentVariable("TERM") != "dumb" &&
        Environment.GetEnvironmentVariable("NO_COLOR") is null;

    internal static string Colorize(string text, ConsoleColor color)
    {
        return SupportsAnsi ? text.Pastel(color) : text;
    }
}