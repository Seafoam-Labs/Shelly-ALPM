using PackageManager.Aur;

namespace Shelly.Commands.AurCommands;

internal static class AurUpdateCommands
{
    internal static async Task<int> UpdateUiMode(string[] packages, bool noConfirm = false)
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

            manager.PackageProgress += (_, args) =>
            {
                Console.Error.WriteLine($"[{args.CurrentIndex}/{args.TotalCount}] {args.PackageName}: {args.Status}" +
                    (args.Message != null ? $" - {args.Message}" : ""));
            };

            manager.Progress += (_, args) =>
            {
                Console.Error.WriteLine($"{args.PackageName}: {args.Percent}%");
            };

            manager.Question += (_, args) =>
            {
                QuestionHandler.HandleQuestion(args, true, noConfirm);
            };

            manager.PkgbuildDiffRequest += (_, args) =>
            {
                if (noConfirm)
                {
                    args.ProceedWithUpdate = true;
                    return;
                }

                Console.Error.WriteLine($"PKGBUILD changed for {args.PackageName}.");
                Console.Error.WriteLine("--- Old PKGBUILD ---");
                Console.Error.WriteLine(args.OldPkgbuild);
                Console.Error.WriteLine("--- New PKGBUILD ---");
                Console.Error.WriteLine(args.NewPkgbuild);
                args.ProceedWithUpdate = true;
            };

            Console.Error.WriteLine($"Updating AUR packages: {string.Join(", ", packages)}");
            await manager.UpdatePackages(packages.ToList());
            Console.Error.WriteLine("Update complete.");

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Update failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    internal static async Task<int> UpdateConsoleMode(string[] packages, bool noConfirm = false)
    {
        if (packages.Length == 0)
        {
            Console.WriteLine("No packages specified.");
            return 1;
        }

        Console.WriteLine($"AUR packages to update: {string.Join(", ", packages)}");

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
            RootElevator.EnsureRootExectuion();
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize(root: true);
            var renderer = new ConsoleProgressRenderer();

            manager.PackageProgress += (_, args) =>
            {
                Console.WriteLine($"[{args.CurrentIndex}/{args.TotalCount}] {args.PackageName}: {args.Status}" +
                    (args.Message != null ? $" - {args.Message}" : ""));
            };

            manager.Question += (_, args) =>
            {
                lock (renderer.RenderLock)
                {
                    renderer.ClearBottomBorder();
                    Console.WriteLine();
                    QuestionHandler.HandleQuestion(args, false, noConfirm);
                }
            };

            manager.PkgbuildDiffRequest += (_, args) =>
            {
                if (noConfirm)
                {
                    args.ProceedWithUpdate = true;
                    return;
                }

                Console.WriteLine($"PKGBUILD changed for {args.PackageName}. View diff? (y/n)");
                var showDiff = Console.ReadLine();
                if (showDiff == "y" || showDiff == "Y")
                {
                    Console.WriteLine("--- Old PKGBUILD ---");
                    Console.WriteLine(args.OldPkgbuild);
                    Console.WriteLine("--- New PKGBUILD ---");
                    Console.WriteLine(args.NewPkgbuild);
                }

                Console.WriteLine($"Proceed with update for {args.PackageName}? (y/n)");
                var proceed = Console.ReadLine();
                args.ProceedWithUpdate = proceed == "y" || proceed == "Y";
            };

            manager.Progress += renderer.HandleProgress;
            await manager.UpdatePackages(packages.ToList());

            if (renderer.HasRows)
                renderer.FinishTable();

            Console.WriteLine("Update complete.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Update failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}
