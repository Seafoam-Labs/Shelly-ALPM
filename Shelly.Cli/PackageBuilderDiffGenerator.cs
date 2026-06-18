using Pastel;

namespace Shelly.Cli;

public static class PackageBuilderDiffGenerator
{
    public static void PrintUnifiedDiff(string oldText, string newText, bool isUiMode = false)
    {
        var oldLines = oldText.Split('\n');
        var newLines = newText.Split('\n');

        // Build LCS table
        var lcs = new int[oldLines.Length + 1, newLines.Length + 1];
        for (var i = oldLines.Length - 1; i >= 0; i--)
        for (var j = newLines.Length - 1; j >= 0; j--)
            lcs[i, j] = oldLines[i].TrimEnd('\r') == newLines[j].TrimEnd('\r')
                ? lcs[i + 1, j + 1] + 1
                : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);

        // Walk the table to produce diff output
        int oi = 0, ni = 0;
        while (oi < oldLines.Length || ni < newLines.Length)
        {
            if (oi < oldLines.Length && ni < newLines.Length &&
                oldLines[oi].TrimEnd('\r') == newLines[ni].TrimEnd('\r'))
            {
                Console.WriteLine($"{oldLines[oi].TrimEnd('\r')}".Pastel(ConsoleColor.White));
                oi++;
                ni++;
            }
            else if (ni < newLines.Length &&
                     (oi >= oldLines.Length || lcs[oi, ni + 1] >= lcs[oi + 1, ni]))
            {
                Console.WriteLine($"{newLines[ni].TrimEnd('\r')}".Pastel(ConsoleColor.Green));
                ni++;
            }
            else
            {
                Console.WriteLine($"{oldLines[oi].TrimEnd('\r')}".Pastel(ConsoleColor.Red));
                oi++;
            }
        }
    }

    public static IEnumerable<string> BuildUnifiedDiffLines(string oldText, string newText)
    {
        var oldLines = oldText.Split('\n');
        var newLines = newText.Split('\n');

        var lcs = new int[oldLines.Length + 1, newLines.Length + 1];
        for (int i = oldLines.Length - 1; i >= 0; i--)
        for (int j = newLines.Length - 1; j >= 0; j--)
            lcs[i, j] = oldLines[i].TrimEnd('\r') == newLines[j].TrimEnd('\r')
                ? lcs[i + 1, j + 1] + 1
                : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);

        var result = new List<string>();
        int oi = 0, ni = 0;
        while (oi < oldLines.Length || ni < newLines.Length)
        {
            if (oi < oldLines.Length && ni < newLines.Length &&
                oldLines[oi].TrimEnd('\r') == newLines[ni].TrimEnd('\r'))
            {
                result.Add($"[white]  {oldLines[oi].TrimEnd('\r')}[/]");
                oi++;
                ni++;
            }
            else if (ni < newLines.Length &&
                     (oi >= oldLines.Length || lcs[oi, ni + 1] >= lcs[oi + 1, ni]))
            {
                result.Add($"[green]+ {newLines[ni].TrimEnd('\r')}[/]");
                ni++;
            }
            else
            {
                result.Add($"[red]- {oldLines[oi].TrimEnd('\r')}[/]");
                oi++;
            }
        }

        return result;
    }
}