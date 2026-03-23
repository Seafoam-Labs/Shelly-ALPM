using PackageManager.Aur;

namespace Shelly.Commands.AurCommands;

internal static class AurUpgradeCommands
{
    internal static async Task<int> UpgradeUiMode(bool noConfirm = false)
    {
        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize(root: true);

            var updates = await manager.GetPackagesNeedingUpdate();

            if (updates.Count == 0)
            {
                Console.Error.WriteLine("All AUR packages are up to date.");
                return 0;
            }

            Console.Error.WriteLine($"{updates.Count} AUR packages need updates:");
            foreach (var pkg in updates)
            {
                Console.Error.WriteLine($"  {pkg.Name}: {pkg.Version} -> {pkg.NewVersion}");
            }

            manager.PackageProgress += (_, args) =>
            {
                Console.Error.WriteLine($"[{args.CurrentIndex}/{args.TotalCount}] {args.PackageName}: {args.Status}" +
                    (args.Message != null ? $" - {args.Message}" : ""));
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

            var packageNames = updates.Select(u => u.Name).ToList();
            await manager.UpdatePackages(packageNames);
            Console.Error.WriteLine("Upgrade complete.");

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Upgrade failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    internal static async Task<int> UpgradeConsoleMode(bool noConfirm = false)
    {
        AurPackageManager? manager = null;
        try
        {
            RootElevator.EnsureRootExectuion();
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize(root: true);

            var updates = await manager.GetPackagesNeedingUpdate();

            if (updates.Count == 0)
            {
                Console.WriteLine("All AUR packages are up to date.");
                return 0;
            }

            Console.WriteLine($"{updates.Count} AUR packages need updates:");
            foreach (var pkg in updates)
            {
                Console.WriteLine($"  {pkg.Name}: {pkg.Version} -> {pkg.NewVersion}");
            }

            if (!noConfirm)
            {
                Console.WriteLine("Proceed with upgrade? (y/n)");
                var input = Console.ReadLine();
                if (input != "y" && input != "Y")
                {
                    Console.WriteLine("Upgrade cancelled.");
                    return 0;
                }
            }

            var renderer = new ConsoleProgressRenderer();

            manager.PackageProgress += (_, args) =>
            {
                Console.WriteLine($"[{args.CurrentIndex}/{args.TotalCount}] {args.PackageName}: {args.Status}" +
                    (args.Message != null ? $" - {args.Message}" : ""));
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

            var packageNames = updates.Select(u => u.Name).ToList();
            await manager.UpdatePackages(packageNames);

            if (renderer.HasRows)
                renderer.FinishTable();

            Console.WriteLine("Upgrade complete.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Upgrade failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}
