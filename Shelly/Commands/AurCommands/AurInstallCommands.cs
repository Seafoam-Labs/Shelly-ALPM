using PackageManager.Aur;

namespace Shelly.Commands.AurCommands;

internal static class AurInstallCommands
{
    internal static async Task<int> InstallUiMode(string[] packages, bool noConfirm = false, bool buildDeps = false, bool makeDeps = false)
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

            var packageList = packages.ToList();

            manager.PackageProgress += (_, args) =>
            {
                Console.Error.WriteLine($"[{args.CurrentIndex}/{args.TotalCount}] {args.PackageName}: {args.Status}" +
                                        (args.Message != null ? $" - {args.Message}" : ""));
            };

            manager.Progress += (_, args) => { Console.Error.WriteLine($"{args.PackageName}: {args.Percent}%"); };

            manager.Question += (_, args) => { QuestionHandler.HandleQuestion(args, true, noConfirm); };

            if (buildDeps)
            {
                if (packages.Length > 1)
                {
                    Console.Error.WriteLine("Cannot build dependencies for multiple packages at once.");
                    return 1;
                }

                if (makeDeps)
                {
                    Console.Error.WriteLine("Installing dependencies (including make dependencies)...");
                    await manager.InstallDependenciesOnly(packageList.First(), true);
                    Console.Error.WriteLine("Dependencies installed successfully!");
                    return 0;
                }

                Console.Error.WriteLine("Installing dependencies...");
                await manager.InstallDependenciesOnly(packageList.First(), false);
                Console.Error.WriteLine("Dependencies installed successfully!");
                return 0;
            }

            Console.Error.WriteLine($"Installing AUR packages: {string.Join(", ", packageList)}");
            await manager.InstallPackages(packageList);
            var missingPackages = await GetMissingPackages(manager, packageList);
            if (missingPackages.Count > 0)
            {
                Console.Error.WriteLine(
                    $"Installation failed: Failed to install AUR package(s): {string.Join(", ", missingPackages)}");
                return 1;
            }

            Console.Error.WriteLine("Installation complete.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Installation failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    internal static async Task<int> InstallConsoleMode(string[] packages, bool noConfirm = false, bool buildDeps = false, bool makeDeps = false)
    {
        if (packages.Length == 0)
        {
            Console.WriteLine("No packages specified.");
            return 1;
        }

        var packageList = packages.ToList();

        Console.WriteLine($"AUR packages to install: {string.Join(", ", packageList)}");

        RootElevator.EnsureRootExectuion();
        
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

            if (buildDeps)
            {
                if (packages.Length > 1)
                {
                    Console.WriteLine("Cannot build dependencies for multiple packages at once.");
                    return 0;
                }

                if (makeDeps)
                {
                    Console.WriteLine("Installing dependencies (including make dependencies)...");
                    await manager.InstallDependenciesOnly(packageList.First(), true);
                    Console.WriteLine("Dependencies installed successfully!");
                    return 0;
                }

                Console.WriteLine("Installing dependencies...");
                await manager.InstallDependenciesOnly(packageList.First(), false);
                Console.WriteLine("Dependencies installed successfully!");
                return 0;
            }

            Console.WriteLine($"Installing AUR packages: {string.Join(", ", packages)}");

            manager.Progress += renderer.HandleProgress;
            await manager.InstallPackages(packageList);

            if (renderer.HasRows)
                renderer.FinishTable();

            var missingPackages = await GetMissingPackages(manager, packageList);
            if (missingPackages.Count > 0)
            {
                Console.WriteLine($"Installation failed: {string.Join(", ", missingPackages)}");
                return 1;
            }

            Console.WriteLine("Installation complete.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Installation failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    private static async Task<List<string>> GetMissingPackages(AurPackageManager manager, List<string> packageList)
    {
        var installedPackages = await manager.GetInstalledPackages();
        var installedPackageNames = installedPackages
            .Select(package => package.Name)
            .ToHashSet(StringComparer.Ordinal);

        return packageList
            .Where(packageName => !installedPackageNames.Contains(packageName))
            .ToList();
    }
}
