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

        manager.Question += (_, args) =>
        {
            lock (renderLock)
            {
                Console.Error.WriteLine();
                QuestionHandler.HandleQuestion(args, true, noConfirm);
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
        var renderer = new ConsoleProgressRenderer();

        manager.Replaces += (_, args) =>
        {
            lock (renderer.RenderLock)
            {
                Console.WriteLine();
                QuestionHandler.HandleReplacePkg(args, false, noConfirm);
            }
        };

        manager.Question += (_, args) =>
        {
            lock (renderer.RenderLock)
            {
                Console.WriteLine();
                QuestionHandler.HandleQuestion(args, false, noConfirm);
            }
        };

        manager.Retrieve += renderer.HandleRetrieve;
        manager.Progress += renderer.HandleProgress;

        Console.WriteLine("Checking for system updates...");
        Console.WriteLine("Initializing and syncing repositories...");
        manager.InitializeWithSync();
        var packagesNeedingUpdate = manager.GetPackagesNeedingUpdate();
        if (packagesNeedingUpdate.Count == 0)
        {
            Console.WriteLine("System is up to date!");
            return 0;
        }

        var config = ConfigManager.ReadConfig();
        var sizeDisplay = Enum.Parse<SizeDisplay>(config.FileSizeDisplay);

        Console.WriteLine($"{packagesNeedingUpdate.Count} packages need updates:");
        ConsoleProgressRenderer.RenderUpdateTable(packagesNeedingUpdate, sizeDisplay, config.FileSizeDisplay);

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
}