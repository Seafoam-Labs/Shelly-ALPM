using PackageManager.Alpm;
namespace Shelly.Commands.StandardCommands;

internal static class InstallCommands
{
    internal static int InstallUiMode(string[] packages, bool verbose = false, bool noConfirm = false, bool buildDeps = false, bool makeDeps = false, bool noDeps = false)
    {
        if (packages.Length == 0)
        {
            Console.Error.WriteLine("Error: No packages specified");
            return 1;
        }

        var manager = new AlpmManager(verbose, true, Configuration.GetConfigurationFilePath());
        manager.Question += (_, args) => { QuestionHandler.HandleQuestion(args, true, noConfirm); };
        Console.Error.WriteLine("Initializing and syncing ALPM...");
        manager.Initialize(true);

        if (buildDeps)
        {
            if (packages.Length > 1)
            {
                Console.WriteLine("Cannot build dependencies for multiple packages at once.");
                return -1;
            }

            if (makeDeps)
            {
                Console.Error.WriteLine("Installing packages...");
                manager.InstallDependenciesOnly(packages[0], true, AlpmTransFlag.None);
                return 0;
            }

            Console.Error.WriteLine("Installing packages...");
            manager.InstallDependenciesOnly(packages[0], false, AlpmTransFlag.None);
            Console.Error.WriteLine("Packages installed successfully!");
            return 0;
        }

        if (noDeps)
        {
            Console.Error.WriteLine("Skipping dependency installation.");
            Console.Error.WriteLine("Installing packages...");
            manager.InstallPackages(packages.ToList(), AlpmTransFlag.NoDeps);
            Console.Error.WriteLine("Packages installed successfully!");
            return 0;
        }

        Console.WriteLine("Installing packages...");
        manager.Progress += (_, args) => { Console.Error.WriteLine($"{args.PackageName}: {args.Percent}%"); };
        try
        {
            manager.InstallPackages(packages.ToList());
            Console.Error.WriteLine("Finished installing packages.");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ALPM_ERROR]Failed to install packages: {ex.Message}");
            manager.Dispose();
            return 1;
        }

        manager.Dispose();
        return 0;
    }

    internal static int InstallConsoleMode(string[] packages, bool verbose = false, bool noConfirm = false, bool buildDeps = false, bool makeDeps = false, bool noDeps = false)
    {
        if (packages.Length == 0)
        {
            Console.WriteLine("Error: No packages specified");
            return 1;
        }

        RootElevator.EnsureRootExectuion();
        var packageList = packages.ToList();
        Console.WriteLine($"Packages to install: {string.Join(", ", packageList)}");

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

        var manager = new AlpmManager(verbose, false, Configuration.GetConfigurationFilePath());
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

        Console.WriteLine("Initializing...");
        manager.Initialize(true);

        if (buildDeps)
        {
            if (packages.Length > 1)
            {
                Console.WriteLine("Cannot build dependencies for multiple packages at once.");
                return 0;
            }

            if (makeDeps)
            {
                Console.WriteLine("Installing packages...");
                manager.InstallDependenciesOnly(packageList.First(), true, AlpmTransFlag.None);
                return 0;
            }

            Console.WriteLine("Installing packages...");
            manager.InstallDependenciesOnly(packageList.First(), false, AlpmTransFlag.None);
            Console.WriteLine("Packages installed successfully!");
            return 0;
        }

        if (noDeps)
        {
            Console.WriteLine("Skipping dependency installation.");
            Console.WriteLine("Installing packages...");
            manager.InstallPackages(packageList, AlpmTransFlag.NoDeps);
            Console.WriteLine("Packages installed successfully!");
            return 0;
        }

        Console.WriteLine("Installing packages...");
        manager.Retrieve += renderer.HandleRetrieve;
        manager.Progress += renderer.HandleProgress;
        manager.InstallPackages(packageList);
        if (renderer.HasRows)
            renderer.FinishTable();

        manager.Dispose();
        Console.WriteLine("Packages installed successfully!");
        return 0;
    }
}
