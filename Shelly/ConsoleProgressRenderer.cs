using PackageManager.Alpm;
using Shelly.Configurations;

namespace Shelly;

/// <summary>
/// Shared console progress rendering for download table display.
/// Used by both SyncCommands and UpgradeCommands console modes.
/// </summary>
internal sealed class ConsoleProgressRenderer
{
    private readonly Dictionary<string, int> _rowIndex = new();
    private readonly object _renderLock = new();
    private int _baseTop = -1;


    private const int NameWidth = 30;
    private const int BarWidth = 20;
    private const int PctWidth = 4;
    private const int StatusWidth = 18;

    public object RenderLock => _renderLock;


    public void HandleRetrieve(object? sender, AlpmRetrieveEventArgs args)
    {
        lock (_renderLock)
        {
            switch (args.Status)
            {
                case AlpmRetrieveStatus.Start:
                    FinishTableBorder();
                    Console.WriteLine(args.RetrieveType == AlpmRetrieveType.DatabaseRetrieve
                        ? "Synchronizing package databases..."
                        : "Retrieving packages...");
                    _rowIndex.Clear();
                    _baseTop = -1;
                    break;
                case AlpmRetrieveStatus.Done:
                    FinishTableBorder();
                    break;
                case AlpmRetrieveStatus.Failed:
                    FinishTableBorder();
                    Console.WriteLine(args.RetrieveType == AlpmRetrieveType.DatabaseRetrieve
                        ? "error: failed to synchronize all databases"
                        : "error: failed to retrieve some files");
                    break;
            }
        }
    }


    public void HandleProgress(object? sender, AlpmProgressEventArgs args)
    {
        if (args.ProgressType is not (AlpmProgressType.PackageDownload or AlpmProgressType.DatabaseDownload))
            return;

        lock (_renderLock)
        {
            var key = args.PackageName ?? "unknown";
            var displayName = key.Length > NameWidth ? key[..NameWidth] : key;
            var pct = args.Percent ?? 0;
            var bar = new string('\uFFED', pct / 5) + new string('\uFFED', BarWidth - pct / 5);
            var status = pct >= 100 ? "Done" : "Downloading";

            var isNew = !_rowIndex.ContainsKey(key);

            if (isNew)
            {
                if (_baseTop < 0)
                {
                    PrintTopBorder();
                    PrintHeaderRow();
                    PrintSeparator();
                    _baseTop = Console.CursorTop;
                }

                var row = _rowIndex.Count;
                _rowIndex[key] = row;
                
                

                // Move to where the bottom border currently sits (or where row 0 will go)
                // and use WriteLine to ensure the terminal buffer extends by one line.
                Console.SetCursorPosition(0, _baseTop + row);
                Console.WriteLine(); // THIS creates the new line in the terminal buffer

                // Now go back and write the data row at its position
                Console.SetCursorPosition(0, _baseTop + row);
                WriteDataRow(displayName, bar, pct, status);

                // Move to the line below and draw the bottom border
                // This line now EXISTS because of the WriteLine() above
                Console.SetCursorPosition(0, _baseTop + row + 1);
                Console.Write("\x1b[2K");
                PrintBottomBorder();
            }
            else
            {
                var row = _rowIndex[key];
                Console.SetCursorPosition(0, _baseTop + row);
                WriteDataRow(displayName, bar, pct, status);
            }

            Console.Out.Flush();
        }
    }


    public void FinishTable()
    {
        lock (_renderLock)
        {
            FinishTableBorder();
            Console.WriteLine();
        }
    }


    public bool HasRows
    {
        get
        {
            lock (_renderLock)
            {
                return _baseTop >= 0;
            }
        }
    }


    public static void RenderUpdateTable(List<AlpmPackageUpdateDto> packages, SizeDisplay sizeDisplay, string sizeLabel)
    {
        var nameHeader = "Package";
        var curHeader = "Current Version";
        var newHeader = "New Version";
        var sizeHeader = $"Download Size ({sizeLabel})";

        var nameW = Math.Max(nameHeader.Length, packages.Max(p => p.Name.Length));
        var curW = Math.Max(curHeader.Length, packages.Max(p => p.CurrentVersion.Length));
        var newW = Math.Max(newHeader.Length, packages.Max(p => p.NewVersion.Length));
        var sizeW = Math.Max(sizeHeader.Length,
            packages.Max(p => FormatDownloadSize(sizeDisplay, p.DownloadSize).Length));

        var top =
            $"\u250c\u2500{new string('\u2500', nameW)}\u2500\u252c\u2500{new string('\u2500', curW)}\u2500\u252c\u2500{new string('\u2500', newW)}\u2500\u252c\u2500{new string('\u2500', sizeW)}\u2500\u2510";
        var sep =
            $"\u251c\u2500{new string('\u2500', nameW)}\u2500\u253c\u2500{new string('\u2500', curW)}\u2500\u253c\u2500{new string('\u2500', newW)}\u2500\u253c\u2500{new string('\u2500', sizeW)}\u2500\u2524";
        var bottom =
            $"\u2514\u2500{new string('\u2500', nameW)}\u2500\u2534\u2500{new string('\u2500', curW)}\u2500\u2534\u2500{new string('\u2500', newW)}\u2500\u2534\u2500{new string('\u2500', sizeW)}\u2500\u2518";

        Console.WriteLine(top);
        Console.WriteLine(
            $"\u2502 {nameHeader.PadRight(nameW)} \u2502 {curHeader.PadRight(curW)} \u2502 {newHeader.PadRight(newW)} \u2502 {sizeHeader.PadRight(sizeW)} \u2502");
        Console.WriteLine(sep);
        foreach (var pkg in packages)
        {
            var size = FormatDownloadSize(sizeDisplay, pkg.DownloadSize);
            Console.WriteLine(
                $"\u2502 {pkg.Name.PadRight(nameW)} \u2502 {pkg.CurrentVersion.PadRight(curW)} \u2502 {pkg.NewVersion.PadRight(newW)} \u2502 {size.PadRight(sizeW)} \u2502");
        }

        Console.WriteLine(bottom);
    }

    public static string FormatDownloadSize(SizeDisplay size, long downloadSize)
    {
        return size switch
        {
            SizeDisplay.Bytes => downloadSize.ToString(),
            SizeDisplay.Megabytes => (downloadSize / 1024).ToString(),
            SizeDisplay.Gigabytes => ((downloadSize / 1024) / 1024).ToString(),
            _ => downloadSize.ToString()
        };
    }

    private static void PrintTopBorder()
    {
        Console.WriteLine(
            $"\u250c\u2500{new string('\u2500', NameWidth)}\u2500\u252c\u2500{new string('\u2500', BarWidth)}\u2500\u252c\u2500{new string('\u2500', PctWidth)}\u2500\u252c\u2500{new string('\u2500', StatusWidth)}\u2500\u2510");
    }

    private static void PrintHeaderRow()
    {
        Console.WriteLine(
            $"\u2502 {"Name".PadRight(NameWidth)} \u2502 {"Progress".PadRight(BarWidth)} \u2502 {"%".PadRight(PctWidth)} \u2502 {"Status".PadRight(StatusWidth)} \u2502");
    }

    private static void PrintSeparator()
    {
        Console.Write(
            $"\u251c\u2500{new string('\u2500', NameWidth)}\u2500\u253c\u2500{new string('\u2500', BarWidth)}\u2500\u253c\u2500{new string('\u2500', PctWidth)}\u2500\u253c\u2500{new string('\u2500', StatusWidth)}\u2500\u2524");
    }

    private static void PrintBottomBorder()
    {
        Console.Write(
            $"\u2514\u2500{new string('\u2500', NameWidth)}\u2500\u2534\u2500{new string('\u2500', BarWidth)}\u2500\u2534\u2500{new string('\u2500', PctWidth)}\u2500\u2534\u2500{new string('\u2500', StatusWidth)}\u2500\u2518");
    }

    private static void WriteDataRow(string name, string bar, int pct, string status)
    {
        Console.Write("\x1b[2K");
        Console.Write(
            $"\u2502 {name.PadRight(NameWidth)} \u2502 {bar.PadRight(BarWidth)} \u2502 {pct.ToString().PadLeft(PctWidth)} \u2502 {status.PadRight(StatusWidth)} \u2502");
    }

    private void FinishTableBorder()
    {
        if (_baseTop >= 0)
        {
            Console.SetCursorPosition(0, _baseTop + _rowIndex.Count);
            Console.Write("\x1b[2K");
            PrintBottomBorder();
        }
    }
}