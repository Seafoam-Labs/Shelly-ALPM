using System.Text.Json;
using PackageManager.Aur;

namespace Shelly.Commands.AurCommands;

internal static class AurSearchPackageBuildCommands
{
    internal static async Task<int> SearchPackageBuildUiMode(string[] packages)
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

            var packageBuild = new List<PackageBuild>();
            foreach (var package in packages)
            {
                var pkgbuild = await manager.FetchPkgbuildAsync(package);
                packageBuild.Add(new PackageBuild(package, pkgbuild));
            }

            var json = JsonSerializer.Serialize(packageBuild, ShellyJsonContext.Default.ListPackageBuild);
            await using var stdout = Console.OpenStandardOutput();
            await using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            await writer.WriteLineAsync(json);
            await writer.FlushAsync();

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to get pkgbuild: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    internal static async Task<int> SearchPackageBuildConsoleMode(string[] packages)
    {
        if (packages.Length == 0)
        {
            Console.WriteLine("No packages specified.");
            return 1;
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager(Configuration.GetConfigurationFilePath());
            await manager.Initialize();

            foreach (var package in packages)
            {
                var pkgbuild = await manager.FetchPkgbuildAsync(package);

                if (pkgbuild == null)
                {
                    Console.WriteLine($"Failed to get pkgbuild for: {package}");
                }
                else
                {
                    Console.WriteLine($"Package build for: {package}");
                    Console.WriteLine(pkgbuild);
                }
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to get pkgbuild: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    public record PackageBuild(string Name, string? PkgBuild);
}
