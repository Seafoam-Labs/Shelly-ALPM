using Spectre.Console;

namespace Shelly_CLI.Utility;

public static class PackageBuilderDiffGenerator
{
    public static void PrintUnifiedDiff(string oldText, string newText, bool isUiMode = false)
    {
        var oldLines = oldText.Split('\n');
        var newLines = newText.Split('\n');

        // Build LCS table
        var lcs = new int[oldLines.Length + 1, newLines.Length + 1];
        for (int i = oldLines.Length - 1; i >= 0; i--)
        for (int j = newLines.Length - 1; j >= 0; j--)
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
                if (isUiMode)
                {
                    Console.Error.WriteLine($"{oldLines[oi].TrimEnd('\r').EscapeMarkup()}");
                }

                AnsiConsole.MarkupLine($"[white]  {oldLines[oi].TrimEnd('\r').EscapeMarkup()}[/]");
                oi++;
                ni++;
            }
            else if (ni < newLines.Length &&
                     (oi >= oldLines.Length || lcs[oi, ni + 1] >= lcs[oi + 1, ni]))
            {
                if (isUiMode)
                {
                    Console.Error.WriteLine($"[Addition+] {newLines[ni].TrimEnd('\r').EscapeMarkup()}");
                }

                AnsiConsole.MarkupLine($"[green]+ {newLines[ni].TrimEnd('\r').EscapeMarkup()}[/]");
                ni++;
            }
            else
            {
                if (isUiMode)
                {
                    Console.Error.WriteLine($"[Removal-] {oldLines[oi].TrimEnd('\r').EscapeMarkup()}");
                }

                AnsiConsole.MarkupLine($"[red]- {oldLines[oi].TrimEnd('\r').EscapeMarkup()}[/]");
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
                result.Add($"[white]  {oldLines[oi].TrimEnd('\r').EscapeMarkup()}[/]");
                oi++; ni++;
            }
            else if (ni < newLines.Length &&
                     (oi >= oldLines.Length || lcs[oi, ni + 1] >= lcs[oi + 1, ni]))
            {
                result.Add($"[green]+ {newLines[ni].TrimEnd('\r').EscapeMarkup()}[/]");
                ni++;
            }
            else
            {
                result.Add($"[red]- {oldLines[oi].TrimEnd('\r').EscapeMarkup()}[/]");
                oi++;
            }
        }
        return result;
    }
    
}