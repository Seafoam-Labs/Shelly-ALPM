using PackageManager.Alpm;
namespace Shelly.Commands.StandardCommands;

internal static class RemoveCommands
{
    internal static int RemoveUiMode(string[] packages, bool verbose = false, bool noConfirm = false, bool cascade = true, bool removeConfig = false)
    {
        if (packages.Length == 0)
        {
            Console.Error.WriteLine("Error: No packages specified");
            return 1;
        }

        using var manager = new AlpmManager(verbose, true, Configuration.GetConfigurationFilePath());
        try
        {
            var packageList = packages.ToList();
            manager.Question += (_, args) => { QuestionHandler.HandleQuestion(args, true, noConfirm); };
            manager.Progress += (_, args) => { Console.Error.WriteLine($"{args.PackageName}: {args.Percent}%"); };
            Console.Error.WriteLine("Initializing...");
            manager.Initialize(true);
            Console.Error.WriteLine($"Removing packages: {string.Join(", ", packageList)}");

            if (cascade)
                manager.RemovePackages(packageList, AlpmTransFlag.Cascade);
            else
                manager.RemovePackages(packageList);

            if (removeConfig)
                HandleConfigRemoval(packages);

            Console.Error.WriteLine("Packages removed successfully!");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Removal failed: {ex.Message}");
            return 1;
        }
    }

    internal static int RemoveConsoleMode(string[] packages, bool verbose = false, bool noConfirm = false, bool cascade = false, bool removeConfig = false)
    {
        if (packages.Length == 0)
        {
            Console.WriteLine("Error: No packages specified");
            return 1;
        }

        RootElevator.EnsureRootExectuion();
        var packageList = packages.ToList();
        Console.WriteLine($"Packages to remove: {string.Join(", ", packageList)}");

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

        Console.WriteLine("Initializing ALPM...");
        manager.Initialize(true);
        Console.WriteLine("Removing packages...");

        manager.Retrieve += renderer.HandleRetrieve;
        manager.Progress += renderer.HandleProgress;

        if (cascade)
            manager.RemovePackages(packageList, AlpmTransFlag.Cascade);
        else
            manager.RemovePackages(packageList);

        if (renderer.HasRows)
            renderer.FinishTable();

        if (removeConfig)
            HandleConfigRemoval(packages);

        Console.WriteLine("Packages removed successfully!");
        return 0;
    }

    private static void HandleConfigRemoval(string[] packageNames)
    {
        foreach (var package in packageNames)
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), package);
            try
            {
                Directory.Delete(path, true);
            }
            catch (Exception)
            {
                Console.WriteLine($"Failed to find directory for {package} moving on");
            }
        }
    }
}
