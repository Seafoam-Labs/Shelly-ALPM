using System.Text;
using Shelly_CLI.Configuration;

namespace Shelly_CLI.ConsoleLayouts;

public static class ProgressBarRenderer
{
    private static readonly char[] Mouth = ['C', 'c'];
    private const char Body = '-';
    private const char Pellet = 'o';
    private const char Empty = ' ';

    public static bool ShouldAnimate(ProgressBarStyleKind style) => style == ProgressBarStyleKind.Pacman;

    /// <summary>Whether this style benefits from a periodic frame ticker (mouth animation).</summary>
    public static bool NeedsFrameTicker(ProgressBarStyleKind style) => style == ProgressBarStyleKind.Pacman;

    /// <summary>
    /// Render a color-free, ASCII-only bar. Pacman style preserves its shape (mouth + pellets),
    /// just stripped of Spectre markup tags. Blocks style falls back to '#'/'-' for non-UTF8 consoles.
    /// </summary>
    public static string RenderAscii(int pct, int frame, ProgressBarStyleKind style, int width)
    {
        pct = Math.Clamp(pct, 0, 100);
        if (width <= 0) width = 24;
        return style switch
        {
            ProgressBarStyleKind.Pacman => Spectre.Console.Markup.Remove(BuildPacmanBar(pct, frame, width)),
            _ => BuildAsciiBlocksBar(pct, width)
        };
    }

    private static string BuildAsciiBlocksBar(int pct, int width)
    {
        int filled = width * pct / 100;
        return new string('#', filled) + new string('-', width - filled);
    }

    public static ProgressBarStyleKind ParseStyle(string? value)
    {
        return Enum.TryParse<ProgressBarStyleKind>(value, true, out var s)
            ? s
            : ProgressBarStyleKind.Blocks;
    }

    public static string Render(int pct, int frame, ProgressBarStyleKind style, int width)
    {
        pct = Math.Clamp(pct, 0, 100);
        if (width <= 0)
        {
            try { width = Math.Max(10, Console.WindowWidth / 3); }
            catch { width = 24; }
        }

        return style switch
        {
            ProgressBarStyleKind.Pacman => BuildPacmanBar(pct, frame, width),
            _ => BuildBlocksBar(pct, width)
        };
    }

    public static string RenderStatic(int pct, int width)
    {
        pct = Math.Clamp(pct, 0, 100);
        if (width <= 0) width = 20;
        return BuildBlocksBar(pct, width);
    }

    private static string BuildBlocksBar(int pct, int width)
    {
        int filled = width * pct / 100;
        return new string('█', filled) + new string('░', width - filled);
    }

    private static string BuildPacmanBar(int pct, int frame, int width)
    {
        int hashlen = width * pct / 100;
        var sb = new StringBuilder(width * 8);

        sb.Append("[yellow]");
        if (hashlen > 0)
        {
            int trail = Math.Max(0, hashlen - 1);
            if (trail > 0) sb.Append(new string(Body, trail));

            if (pct < 100)
                sb.Append(Mouth[frame & 1]);
            else
                sb.Append(Body);
        }
        sb.Append("[/]");

        sb.Append("[white]");
        for (int i = hashlen; i < width; i++)
        {
            bool isPelletSlot = ((i - hashlen) % 2 == 0) && pct < 100;
            sb.Append(isPelletSlot ? Pellet : Empty);
        }
        sb.Append("[/]");

        return sb.ToString();
    }
}
