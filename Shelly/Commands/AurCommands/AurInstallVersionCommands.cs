using PackageManager.Aur;

namespace Shelly.Commands.AurCommands;

internal static class AurInstallVersionCommands
{
    internal static async Task<int> InstallVersionUiMode(string package, string commit)
    {
        if (string.IsNullOrWhiteSpace(package))
        {
            Console.Error.WriteLine("Error: No package specified.");
            return 1;
        }

        if (string.IsNullOrWhiteSpace(commit))
        {
            Console.Error.WriteLine("Error: No commit specified.");
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

            Console.Error.WriteLine($"Installing AUR package {package} at commit {commit}");
            await manager.InstallPackageVersion(package, commit);
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

    internal static async Task<int> InstallVersionConsoleMode(string package, string commit)
    {
        if (string.IsNullOrWhiteSpace(package))
        {
            Console.WriteLine("No package specified.");
            return 1;
        }

        if (string.IsNullOrWhiteSpace(commit))
        {
            Console.WriteLine("No commit specified.");
            return 1;
        }

        AurPackageManager? manager = null;
        try
        {
            RootElevator.EnsureRootExectuion();
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize(root: true);

            manager.PackageProgress += (_, args) =>
            {
                Console.WriteLine($"[{args.CurrentIndex}/{args.TotalCount}] {args.PackageName}: {args.Status}" +
                    (args.Message != null ? $" - {args.Message}" : ""));
            };

            Console.WriteLine($"Installing AUR package {package} at commit {commit}");
            await manager.InstallPackageVersion(package, commit);
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
}
