using PackageManager.Alpm;
namespace Shelly.Commands.StandardCommands;

internal static class PackageInfoCommands
{
    internal static int PackageInfoUiMode(string[] packages, bool verbose, bool installed, bool repository)
    {
        Console.WriteLine("Not supported for ui methods yet");
        return 0;
    }

    internal static int PackageInfoConsoleMode(string[] packages, bool verbose, bool installed, bool repository)
    {
        if (packages.Length > 1)
        {
            Console.WriteLine("Only one package at a time is currently supported.");
            return 0;
        }

        if (packages.Length == 0)
        {
            Console.WriteLine("Error: No packages specified");
            return 1;
        }

        var manager = new AlpmManager(verbose, false, Configuration.GetConfigurationFilePath());
        AlpmPackageDto? package = null;

        if (installed)
        {
            manager.Initialize(true);
            var installedPackages = manager.GetInstalledPackages();
            package = installedPackages.FirstOrDefault(x => x.Name == packages[0]);
        }
        else if (repository)
        {
            manager.Initialize();
            var available = manager.GetAvailablePackages();
            package = available.FirstOrDefault(x => x.Name == packages[0]);
        }
        else
        {
            Console.WriteLine("No search source specified");
            manager.Dispose();
            return 0;
        }

        if (package is null)
        {
            Console.WriteLine($"No package named {packages[0]} found");
            manager.Dispose();
            return 0;
        }

        Console.WriteLine($"Name: {package.Name}");
        Console.WriteLine($"Version: {package.Version}");
        Console.WriteLine($"Description: {package.Description}");
        Console.WriteLine($"URL: {package.Url}");
        Console.WriteLine($"Licenses: {string.Join(',', package.Licenses)}");
        Console.WriteLine($"Groups: {string.Join(',', package.Groups)}");
        Console.WriteLine($"Provides: {string.Join(',', package.Provides)}");
        Console.WriteLine($"Depends On: {string.Join(',', package.Depends)}");
        Console.WriteLine($"Optional Depends: {string.Join(',', package.OptDepends)}");
        Console.WriteLine($"Required By: {string.Join(',', package.RequiredBy)}");
        Console.WriteLine($"Conflicts With: {string.Join(',', package.Conflicts)}");
        Console.WriteLine($"Replaces: {string.Join(',', package.Replaces)}");
        Console.WriteLine($"Installed Size: {package.InstalledSize} bytes");
        var installDate = package.InstallDate.HasValue
            ? package.InstallDate.Value.ToLongDateString()
            : "Not Installed";
        Console.WriteLine($"Install Date: {installDate}");
        Console.WriteLine($"Install Reason: {package.InstallReason}");

        manager.Dispose();
        return 0;
    }
}
