using PackageManager.Alpm;
namespace Shelly.Commands.StandardCommands;

internal static class InstallLocalCommands
{
    internal static int InstallLocalUiMode(string? location, bool verbose = false, bool noConfirm = false)
    {
        if (string.IsNullOrEmpty(location))
        {
            Console.Error.WriteLine("Error: No package location specified");
            return 1;
        }

        if (!File.Exists(location))
        {
            Console.Error.WriteLine("Error: Specified file does not exist.");
            return 1;
        }

        var manager = new AlpmManager(verbose, true, Configuration.GetConfigurationFilePath());
        manager.Question += (_, args) => { QuestionHandler.HandleQuestion(args, true, noConfirm); };
        manager.Progress += (_, args) => { Console.Error.WriteLine($"{args.PackageName}: {args.Percent}%"); };
        Console.Error.WriteLine("Initializing ALPM...");
        manager.Initialize(true);

        try
        {
            Console.Error.WriteLine("Installing local package...");
            manager.InstallLocalPackage(location);
            Console.Error.WriteLine("Local package installed successfully!");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ALPM_ERROR]Failed to install local package: {ex.Message}");
            manager.Dispose();
            return 1;
        }

        manager.Dispose();
        return 0;
    }

    internal static int InstallLocalConsoleMode(string? location, bool verbose = false, bool noConfirm = false)
    {
        if (string.IsNullOrEmpty(location))
        {
            Console.WriteLine("Error: No package location specified");
            return 1;
        }

        if (!File.Exists(location))
        {
            Console.WriteLine("Error: Specified file does not exist.");
            return 1;
        }

        RootElevator.EnsureRootExectuion();

        if (!noConfirm)
        {
            Console.WriteLine($"Install local package: {location}");
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

        manager.Retrieve += renderer.HandleRetrieve;
        manager.Progress += renderer.HandleProgress;

        Console.WriteLine("Initializing ALPM...");
        manager.Initialize(true);

        try
        {
            Console.WriteLine("Installing local package...");
            manager.InstallLocalPackage(location);
            if (renderer.HasRows)
                renderer.FinishTable();
            Console.WriteLine("Local package installed successfully!");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to install local package: {ex.Message}");
            manager.Dispose();
            return 1;
        }

        manager.Dispose();
        return 0;
    }
}
