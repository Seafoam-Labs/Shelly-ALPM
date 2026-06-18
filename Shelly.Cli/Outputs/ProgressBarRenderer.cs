using System.Text;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Utilities.Enums;

namespace Shelly.Cli.Outputs;

internal static class ProgressBarRenderer
{
    private static readonly char[] Mouth = ['C', 'c'];
    private const char Body = '-';
    private const char Pellet = 'o';
    private const char Empty = ' ';

    public static bool ShouldAnimate(ProgressBarStyleKind style) => style == ProgressBarStyleKind.Pacman;

    /// <summary>Whether this style benefits from a periodic frame ticker (mouth animation).</summary>
    public static bool NeedsFrameTicker(ProgressBarStyleKind style) => style == ProgressBarStyleKind.Pacman;

    public static ProgressBarStyleKind ParseStyle(string? value) =>
        Enum.TryParse<ProgressBarStyleKind>(value, true, out var s)
            ? s
            : ProgressBarStyleKind.Blocks;

    /// <summary>
    /// Render a color-free, ASCII-only bar. Pacman style preserves its shape (mouth + pellets),
    /// just stripped of color. Blocks style falls back to '#'/'-' for non-UTF8 consoles.
    /// </summary>
    public static string RenderAscii(int pct, int frame, ProgressBarStyleKind style, int width)
    {
        pct = Math.Clamp(pct, 0, 100);
        if (width <= 0) width = 24;
        return style switch
        {
            ProgressBarStyleKind.Pacman => AnsiText.StripAnsi(BuildPacmanBar(pct, frame, width, ansi: false)),
            _ => BuildAsciiBlocksBar(pct, width)
        };
    }

    public static string Render(int pct, int frame, ProgressBarStyleKind style, int width)
    {
        pct = Math.Clamp(pct, 0, 100);
        if (width <= 0)
        {
            try { width = Math.Max(10, Console.WindowWidth / 3); }
            catch { width = 24; }
        }

        var ansi = AnsiUtilities.SupportsAnsi;
        return style switch
        {
            ProgressBarStyleKind.Pacman => BuildPacmanBar(pct, frame, width, ansi),
            _ => BuildBlocksBar(pct, width)
        };
    }

    public static string RenderStatic(int pct, int width)
    {
        pct = Math.Clamp(pct, 0, 100);
        if (width <= 0) width = 20;
        return BuildBlocksBar(pct, width);
    }

    private static string BuildAsciiBlocksBar(int pct, int width)
    {
        var filled = width * pct / 100;
        return new string('#', filled) + new string('-', width - filled);
    }

    private static string BuildBlocksBar(int pct, int width)
    {
        var filled = width * pct / 100;
        return new string('█', filled) + new string('░', width - filled);
    }

    private static string BuildPacmanBar(int pct, int frame, int width, bool ansi)
    {
        var hashlen = width * pct / 100;

        var eaten = new StringBuilder(width);
        if (hashlen > 0)
        {
            var trail = Math.Max(0, hashlen - 1);
            if (trail > 0) eaten.Append(new string(Body, trail));
            eaten.Append(pct < 100 ? Mouth[frame & 1] : Body);
        }

        var rest = new StringBuilder(width);
        for (var i = hashlen; i < width; i++)
        {
            var isPelletSlot = (i - hashlen) % 2 == 0 && pct < 100;
            rest.Append(isPelletSlot ? Pellet : Empty);
        }

        if (!ansi)
            return eaten.ToString() + rest;

        return eaten.ToString().Pastel(ConsoleColor.Yellow) + rest.ToString().Pastel(ConsoleColor.White);
    }
}
