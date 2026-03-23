using PackageManager.Aur;

namespace Shelly.Commands.AurCommands;

internal static class AurRemoveCommands
{
    internal static async Task<int> RemoveUiMode(string[] packages, bool noConfirm = false)
    {
        if (packages.Length == 0)
        {
            Console.Error.WriteLine("Error: No packages specified");
            return 1;
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize(root: true);

            manager.Progress += (_, args) => { Console.Error.WriteLine($"{args.PackageName}: {args.Percent}%"); };
            manager.Question += (_, args) => { QuestionHandler.HandleQuestion(args, true, noConfirm); };

            var packageList = packages.ToList();
            Console.Error.WriteLine($"Removing AUR packages: {string.Join(", ", packageList)}");
            await manager.RemovePackages(packageList);
            Console.Error.WriteLine("Packages removed successfully!");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Removal failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    internal static async Task<int> RemoveConsoleMode(string[] packages, bool noConfirm = false)
    {
        if (packages.Length == 0)
        {
            Console.WriteLine("No packages specified.");
            return 1;
        }

        RootElevator.EnsureRootExectuion();
        var packageList = packages.ToList();
        Console.WriteLine($"AUR packages to remove: {string.Join(", ", packageList)}");

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

        AurPackageManager? manager = null;
        try
        {
            
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize(root: true);
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

            manager.Progress += renderer.HandleProgress;
            await manager.RemovePackages(packageList);

            if (renderer.HasRows)
                renderer.FinishTable();

            Console.WriteLine("Packages removed successfully!");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Removal failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}
