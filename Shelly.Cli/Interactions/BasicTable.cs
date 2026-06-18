using System.Text;
using System.Text.RegularExpressions;
using Pastel;

namespace Shelly.Cli.Interactions;

public static class BasicTable
{
    // Matches ANSI escape sequences so we can measure *visible* width.
    private static readonly Regex AnsiRegex = new("\e\\[[0-9;]*m", RegexOptions.Compiled);

    private static int VisibleLength(string s) => AnsiRegex.Replace(s, "").Length;

    public static string Execute<T>(
        IReadOnlyList<string> headers,
        IReadOnlyList<T> items,
        params Func<T, string>[] columns)
    {
        var rows = items
            .Select(IReadOnlyList<string> (item) => columns.Select(col => col(item)).ToList())
            .ToList();
        return Execute(headers, rows);
    }
    
    public static string Execute(IReadOnlyList<string> headers, IReadOnlyList<IReadOnlyList<string>> rows)
    {
        if (headers.Count == 0)
            return string.Empty;

        var ansi = AnsiUtilities.SupportsAnsi;
        var cols = headers.Count;


        var widths = new int[cols];
        for (var c = 0; c < cols; c++)
            widths[c] = VisibleLength(headers[c]);

        foreach (var row in rows)
            for (var c = 0; c < cols; c++)
            {
                var cell = c < row.Count ? row[c] : "";
                widths[c] = Math.Max(widths[c], VisibleLength(cell));
            }

        
        string Border(char left, char mid, char right) =>
            left + string.Join(mid, widths.Select(w => new string('─', w + 2))) + right;

        
        string Cell(string text, int width)
        {
            var pad = width - VisibleLength(text);
            return " " + text + new string(' ', Math.Max(0, pad)) + " ";
        }

        var sb = new StringBuilder();

        sb.AppendLine(Border('┌', '┬', '┐'));

        
        sb.Append('│');
        for (var c = 0; c < cols; c++)
        {
            var h = ansi ? headers[c].Pastel(ConsoleColor.DarkYellow) : headers[c];
            sb.Append(Cell(h, widths[c])).Append('│');
        }
        sb.AppendLine();

        sb.AppendLine(Border('├', '┼', '┤'));

        
        foreach (var row in rows)
        {
            sb.Append('│');
            for (var c = 0; c < cols; c++)
            {
                var cell = c < row.Count ? row[c] : "";
                sb.Append(Cell(cell, widths[c])).Append('│');
            }
            sb.AppendLine();
        }

        sb.AppendLine(Border('└', '┴', '┘'));

        return sb.ToString();
    }
}