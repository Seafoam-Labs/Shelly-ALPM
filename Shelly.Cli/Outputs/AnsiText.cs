using System.Text;
using System.Text.RegularExpressions;

namespace Shelly.Cli.Outputs;

/// <summary>
/// ANSI-aware text utilities. Replaces Spectre's <c>Markup.Remove</c> / <c>EscapeMarkup</c>
/// for the Pastel-colored world: measure visible width and truncate without ever slicing
/// through an escape sequence (which would leave a dangling color and corrupt cursor math).
/// </summary>
internal static partial class AnsiText
{
    // Matches CSI ... <final byte> (color/SGR and cursor escapes).
    [GeneratedRegex(@"\x1b\[[0-9;]*[A-Za-z]")]
    private static partial Regex AnsiRegex();

    private const string Reset = "\x1b[0m";

    /// <summary>Remove all ANSI escape sequences (replacement for Spectre's Markup.Remove).</summary>
    public static string StripAnsi(string s) =>
        string.IsNullOrEmpty(s) ? s : AnsiRegex().Replace(s, string.Empty);

    /// <summary>Visible (printable) length — what the terminal actually shows.</summary>
    public static int VisibleLength(string s) => StripAnsi(s).Length;

    /// <summary>
    /// Truncate to <paramref name="maxVisible"/> visible characters while preserving
    /// escape sequences intact. Appends a reset if any color code was emitted, so a
    /// truncated colored string never bleeds into the rest of the terminal.
    /// </summary>
    public static string TruncateVisible(string s, int maxVisible)
    {
        if (maxVisible <= 0) return string.Empty;
        if (VisibleLength(s) <= maxVisible) return s;

        var sb = new StringBuilder(s.Length);
        var visible = 0;
        var sawEscape = false;
        var i = 0;

        while (i < s.Length && visible < maxVisible)
        {
            // Copy an escape sequence wholesale (it costs 0 visible columns).
            var m = AnsiRegex().Match(s, i);
            if (m.Success && m.Index == i)
            {
                sb.Append(s, i, m.Length);
                i += m.Length;
                sawEscape = true;
                continue;
            }

            sb.Append(s[i]);
            i++;
            visible++;
        }

        if (sawEscape) sb.Append(Reset);
        return sb.ToString();
    }
}
