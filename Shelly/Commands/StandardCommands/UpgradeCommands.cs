using System.Runtime.InteropServices.ComTypes;
using PackageManager.Alpm;
using Shelly.Configurations;

namespace Shelly.Commands.StandardCommands;

internal static class UpgradeCommands
{
    internal static int UpgradeUiMode(bool verbose = false, bool force = false, bool noConfirm = false)
    {
        object renderLock = new();
        Console.Error.WriteLine("Performing full system upgrade...");

        var manager = new AlpmManager(verbose, true, Configuration.GetConfigurationFilePath());
        manager.Replaces += (_, args) =>
        {
            lock (renderLock)
            {
                Console.Error.WriteLine();
                QuestionHandler.HandleReplacePkg(args, true, noConfirm);
            }
        };

        manager.Progress += (_, args) =>
        {
            lock (renderLock)
            {
                var name = args.PackageName ?? "unknown";
                var pct = args.Percent ?? 0;
                var actionType = args.ProgressType;
                Console.Error.WriteLine($"{name}: {pct}% - {actionType}");
            }
        };

        Console.Error.WriteLine("Checking for system updates...");
        Console.Error.WriteLine("Initializing and syncing repositories...");
        manager.InitializeWithSync();
        Console.Error.WriteLine("Finishing syncing repositories.");
        //Need to add support for dry run
        manager.SyncSystemUpdate();
        Console.WriteLine("System upgraded successfully!");
        manager.Dispose();
        return 0;
    }

    internal static int UpgradeConsole(bool verbose = false, bool force = false, bool noConfirm = false)
    {
        //TODO: Insert ArchNews
        Console.WriteLine("Performing full system upgrade...");
        var manager = new AlpmManager(verbose, false, Configuration.GetConfigurationFilePath());
        object renderLock = new();

        manager.Replaces += (_, args) =>
        {
            lock (renderLock)
            {
                Console.WriteLine();
                QuestionHandler.HandleReplacePkg(args, false, noConfirm);
            }
        };

        manager.Question += (_, args) =>
        {
            lock (renderLock)
            {
                Console.WriteLine();
                QuestionHandler.HandleQuestion(args, false, noConfirm);
            }
        };

        var rowIndex = new Dictionary<string, int>();
        var baseTop = -1;

        manager.Retrieve += (_, args) =>
        {
            lock (renderLock)
            {
                switch (args.Status)
                {
                    case AlpmRetrieveStatus.Start:
                        if (baseTop >= 0)
                            Console.SetCursorPosition(0, baseTop + rowIndex.Count);
                        Console.WriteLine();
                        Console.WriteLine(args.RetrieveType == AlpmRetrieveType.DatabaseRetrieve
                            ? ":: Synchronizing package databases..."
                            : ":: Retrieving packages...");
                        rowIndex.Clear();
                        baseTop = -1;
                        break;
                    case AlpmRetrieveStatus.Done:
                        if (baseTop >= 0)
                            Console.SetCursorPosition(0, baseTop + rowIndex.Count);
                        Console.WriteLine();
                        break;
                    case AlpmRetrieveStatus.Failed:
                        if (baseTop >= 0)
                            Console.SetCursorPosition(0, baseTop + rowIndex.Count);
                        Console.WriteLine();
                        Console.WriteLine(args.RetrieveType == AlpmRetrieveType.DatabaseRetrieve
                            ? "error: failed to synchronize all databases"
                            : "error: failed to retrieve some files");
                        break;
                }
            }
        };

        manager.Progress += (_, args) =>
        {
            lock (renderLock)
            {
                var name = args.PackageName ?? "unknown";
                var pct = args.Percent ?? 0;
                var bar = new string('\u2588', pct / 5) + new string('\u2591', 20 - pct / 5);
                var stage = args.ProgressType;

                var line = $"  {name,-30} {bar} {pct,3}%  {stage}";

                if (!rowIndex.TryGetValue(name, out var row))
                {
                    if (baseTop < 0) baseTop = Console.CursorTop;
                    row = rowIndex.Count;
                    rowIndex[name] = row;
                }

                Console.SetCursorPosition(0, baseTop + row);
                Console.Write("\x1b[2K");
                Console.Write(line);
                Console.Out.Flush();
            }
        };

        Console.WriteLine("Checking for system updates...");
        Console.WriteLine("Initializing and syncing repositories...");
        manager.Initialize();
        var packagesNeedingUpdate = manager.GetPackagesNeedingUpdate();
        if (packagesNeedingUpdate.Count == 0)
        {
            Console.WriteLine("System is up to date!");
            return 0;
        }

        var config = ConfigManager.ReadConfig();
        var sizeDisplay = Enum.Parse<SizeDisplay>(config.FileSizeDisplay);

        Console.WriteLine($"{packagesNeedingUpdate.Count} packages need updates:");

        // Calculate column widths
        var nameHeader = "Package";
        var curHeader = "Current Version";
        var newHeader = "New Version";
        var sizeHeader = $"Download Size ({config.FileSizeDisplay})";

        var nameW = Math.Max(nameHeader.Length, packagesNeedingUpdate.Max(p => p.Name.Length));
        var curW = Math.Max(curHeader.Length, packagesNeedingUpdate.Max(p => p.CurrentVersion.Length));
        var newW = Math.Max(newHeader.Length, packagesNeedingUpdate.Max(p => p.NewVersion.Length));
        var sizeW = Math.Max(sizeHeader.Length,
            packagesNeedingUpdate.Max(p => CalculateDownloadSize(sizeDisplay, p.DownloadSize).Length));

        var top =
            $"┌─{new string('─', nameW)}─┬─{new string('─', curW)}─┬─{new string('─', newW)}─┬─{new string('─', sizeW)}─┐";
        var sep =
            $"├─{new string('─', nameW)}─┼─{new string('─', curW)}─┼─{new string('─', newW)}─┼─{new string('─', sizeW)}─┤";
        var bottom =
            $"└─{new string('─', nameW)}─┴─{new string('─', curW)}─┴─{new string('─', newW)}─┴─{new string('─', sizeW)}─┘";

        Console.WriteLine(top);
        Console.WriteLine(
            $"│ {nameHeader.PadRight(nameW)} │ {curHeader.PadRight(curW)} │ {newHeader.PadRight(newW)} │ {sizeHeader.PadRight(sizeW)} │");
        Console.WriteLine(sep);
        foreach (var pkg in packagesNeedingUpdate)
        {
            var size = CalculateDownloadSize(sizeDisplay, pkg.DownloadSize);
            Console.WriteLine(
                $"│ {pkg.Name.PadRight(nameW)} │ {pkg.CurrentVersion.PadRight(curW)} │ {pkg.NewVersion.PadRight(newW)} │ {size.PadRight(sizeW)} │");
        }

        Console.WriteLine(bottom);

        if (!noConfirm)
        {
            Console.WriteLine("Start system upgrade? (y/n)");
            var input = Console.ReadLine();
            if (input != "y" && input != "Y")
            {
                Console.WriteLine("Cancelling system upgrade.");
                manager.Dispose();
                return 0;
            }
        }

        manager.SyncSystemUpdate();
        Console.WriteLine("System Upgraded Successfully!");
        manager.Dispose();
        return 0;
    }

    private static string CalculateDownloadSize(SizeDisplay size, long downloadSize)
    {
        return size switch
        {
            SizeDisplay.Bytes => downloadSize.ToString(),
            SizeDisplay.Megabytes => (downloadSize / 1024).ToString(),
            SizeDisplay.Gigabytes => ((downloadSize / 1024) / 1024).ToString(),
            _ => downloadSize.ToString()
        };
    }
}