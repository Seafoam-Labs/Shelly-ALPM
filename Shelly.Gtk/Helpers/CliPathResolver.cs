namespace Shelly.Gtk.Helpers;

internal static class CliPathResolver
{
    public static string FindCliPath()
    {
#if DEBUG
        var solutionRoot = FindSolutionRoot(AppContext.BaseDirectory);
        var debugPath = solutionRoot != null
            ? Path.Combine(solutionRoot, "Shelly.Cli", "bin", "Debug", "net10.0", "linux-x64", "shelly")
            : string.Empty;
        Console.Error.WriteLine($"Debug path: {debugPath}");
#endif
        var possiblePaths = new[]
        {
#if DEBUG
            debugPath,
#endif
            "/usr/bin/shelly",
            "/usr/local/bin/shelly",
            Path.Combine(AppContext.BaseDirectory, "shelly"),
            Path.Combine(AppContext.BaseDirectory, "Shelly"),
            Path.Combine(Path.GetDirectoryName(AppContext.BaseDirectory) ?? "", "Shelly", "Shelly"),
        };

        return possiblePaths
            .Where(File.Exists)
            .FirstOrDefault("shelly");
    }

#if DEBUG
    private static string? FindSolutionRoot(string start)
    {
        var dir = new DirectoryInfo(start);
        while (dir != null)
        {
            if (dir.GetFiles("*.slnx").Length > 0)
                return dir.FullName;
            dir = dir.Parent;
        }

        return null;
    }
#endif
}