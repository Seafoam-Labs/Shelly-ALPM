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

        EventHandler<AlpmReplacesEventArgs> replacesHandler = (_, args) =>
        {
            lock (renderer.RenderLock)
            {
                renderer.ClearBottomBorder();
                Console.WriteLine();
                QuestionHandler.HandleReplacePkg(args, false, noConfirm);
            }
        };
        manager.Replaces += replacesHandler;

        EventHandler<AlpmQuestionEventArgs> questionHandler = (_, args) =>
        {
            lock (renderer.RenderLock)
            {
                renderer.ClearBottomBorder();
                Console.WriteLine();
                QuestionHandler.HandleQuestion(args, false, noConfirm);
            }
        };
        manager.Question += questionHandler;

        manager.Retrieve += renderer.HandleRetrieve;
        manager.Progress += renderer.HandleProgress;
        manager.PackageOperation += (_, args) =>
        {
            lock (renderer.RenderLock)
            {
                renderer.ClearBottomBorder();
                Console.WriteLine();
            }
        };

        Console.WriteLine("Checking for system updates...");
        Console.WriteLine("Initializing and syncing repositories...");
        manager.InitializeWithSync();
        renderer.FinishTable();
        var packagesNeedingUpdate = manager.GetPackagesNeedingUpdate();
        if (packagesNeedingUpdate.Count == 0)
        {
            Console.WriteLine();
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


        var freshRenderer = new ConsoleProgressRenderer();
        manager.Retrieve -= renderer.HandleRetrieve;
        manager.Progress -= renderer.HandleProgress;
        manager.Replaces -= replacesHandler;
        manager.Question -= questionHandler;
        manager.Retrieve += freshRenderer.HandleRetrieve;
        manager.Progress += freshRenderer.HandleProgress;
        manager.PackageOperation += (_, args) =>
        {
            lock (freshRenderer.RenderLock)
            {
                freshRenderer.ClearBottomBorder();
                Console.WriteLine();
            }
        };
        manager.Replaces += (_, args) =>
        {
            lock (freshRenderer.RenderLock)
            {
                freshRenderer.ClearBottomBorder();
                Console.WriteLine();
                QuestionHandler.HandleReplacePkg(args, false, noConfirm);
            }
        };
        manager.Question += (_, args) =>
        {
            lock (freshRenderer.RenderLock)
            {
                freshRenderer.ClearBottomBorder();
                Console.WriteLine();
                QuestionHandler.HandleQuestion(args, false, noConfirm);
            }
        };

        manager.SyncSystemUpdate();
        freshRenderer.FinishTable();
        Console.WriteLine("System Upgraded Successfully!");
        manager.Dispose();
        return 0;
    }
}