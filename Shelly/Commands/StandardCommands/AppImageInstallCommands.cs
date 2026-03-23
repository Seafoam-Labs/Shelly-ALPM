namespace Shelly.Commands.StandardCommands;

internal static class AppImageInstallCommands
{
    internal static async Task<int> InstallAppImage(string? location, bool verbose, bool uiMode, bool noConfirm)
    {
        if (string.IsNullOrEmpty(location))
        {
            Console.WriteLine("Error: No AppImage location specified. Use -l to specify the path.");
            return 1;
        }

        if (!File.Exists(location))
        {
            Console.WriteLine($"Error: File not found: {location}");
            return 1;
        }

        if (!location.EndsWith(".AppImage", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine("Error: File does not appear to be an AppImage.");
            return 1;
        }

        var appImageDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".local", "bin", "appimages");

        if (!Directory.Exists(appImageDir))
            Directory.CreateDirectory(appImageDir);

        var destPath = Path.Combine(appImageDir, Path.GetFileName(location));

        if (!noConfirm && !uiMode)
        {
            Console.WriteLine($"Install AppImage to: {destPath}");
            Console.WriteLine("Do you want to proceed? (y/n)");
            var input = Console.ReadLine();
            if (input != "y" && input != "Y")
            {
                Console.WriteLine("Operation cancelled.");
                return 0;
            }
        }

        try
        {
            File.Copy(location, destPath, true);

            // Make executable
            var chmod = new System.Diagnostics.ProcessStartInfo("chmod", $"+x \"{destPath}\"")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            var process = System.Diagnostics.Process.Start(chmod);
            if (process != null) await process.WaitForExitAsync();

            if (uiMode)
                Console.Error.WriteLine($"AppImage installed to: {destPath}");
            else
                Console.WriteLine($"AppImage installed to: {destPath}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to install AppImage: {ex.Message}");
            return 1;
        }

        return 0;
    }
}
