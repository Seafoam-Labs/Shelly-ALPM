using PackageManager.Alpm;

namespace Shelly.Commands.StandardCommands;

internal static class SyncCommands
{
     internal static int SyncUiMode(bool verbose = false, bool force = false)
    {
        var manager = new AlpmManager(verbose, true, Configuration.GetConfigurationFilePath());
        Console.WriteLine("Synchronizing package databases...");
        manager.Progress += (sender, args) => { Console.WriteLine($"{args.PackageName}: {args.Percent}%"); };
        manager.Sync(force);
        Console.WriteLine("Package databases synchronization completed");
        return 0;
    }

    internal static int SyncConsoleMode(bool verbose = false, bool force = false)
    {
        var manager = new AlpmManager(verbose, false, Configuration.GetConfigurationFilePath());
        Console.WriteLine("Synchronizing package databases...");
        if (force)
        {
            Console.WriteLine("Forcing Synchronization");
        }

        var renderer = new ConsoleProgressRenderer();

        manager.Retrieve += renderer.HandleRetrieve;
        manager.Progress += renderer.HandleProgress;

        manager.Sync(force);
        if (renderer.HasRows)
            renderer.FinishTable();
        Console.WriteLine("Package databases synchronization completed");
        return 0;
    }
}
