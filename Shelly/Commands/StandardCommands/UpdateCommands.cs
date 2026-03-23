using PackageManager.Alpm;
namespace Shelly.Commands.StandardCommands;

internal static class UpdateCommands
{
    internal static int UpdateUiMode(List<string> packages, bool verbose = false)
    {
        if (packages.Count == 0)
        {
            Console.Error.WriteLine("Error: No packages specified");
            return 1;
        }

        using var manager = new AlpmManager(verbose, true, Configuration.GetConfigurationFilePath());
        manager.Question += (_, args) => { QuestionHandler.HandleQuestion(args, true); };
        Console.Error.WriteLine("Initializing and syncing...");
        manager.InitializeWithSync();
        Console.Error.WriteLine("Updating packages...");
        manager.Progress += (_, args) => { Console.Error.WriteLine($"{args.PackageName}: {args.Percent}%"); };
        manager.UpdatePackages(packages);
        Console.Error.WriteLine("Packages updated successfully!");
        return 0;
    }

    internal static int UpdateConsoleMode(List<string> packages, bool verbose = false, bool noConfirm = false)
    {
        if (packages.Count == 0)
        {
            Console.WriteLine("Error: No packages specified");
            return 1;
        }

        Console.WriteLine($"Packages to update: {string.Join(", ", packages)}");

        if (!noConfirm)
        {
            Console.WriteLine("Do you want to proceed? (y/n)");
            var input = Console.ReadLine();
            if (input != "y" && input != "Y")
            {
                Console.WriteLine("Operation cancelled.");
                return 0;
            }
        }

        using var manager = new AlpmManager(verbose, false, Configuration.GetConfigurationFilePath());
        var renderer = new ConsoleProgressRenderer();

        manager.Question += (_, args) =>
        {
            lock (renderer.RenderLock)
            {
                renderer.ClearBottomBorder();
                Console.WriteLine();
                QuestionHandler.HandleQuestion(args, false, noConfirm);
            }
        };

        Console.WriteLine("Initializing and syncing...");
        manager.InitializeWithSync();
        Console.WriteLine("Updating packages...");

        manager.Retrieve += renderer.HandleRetrieve;
        manager.Progress += renderer.HandleProgress;
        manager.UpdatePackages(packages);

        if (renderer.HasRows)
            renderer.FinishTable();

        Console.WriteLine("Packages updated successfully!");
        return 0;
    }
}
