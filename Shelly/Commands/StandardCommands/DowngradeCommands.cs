using System.Text.RegularExpressions;
using PackageManager.Alpm;
namespace Shelly.Commands.StandardCommands;

internal static class DowngradeCommands
{
    private const string ArchRepo = "https://archive.archlinux.org/packages/";

    internal static int DowngradeUiMode(string[] packages, bool verbose, bool noConfirm, bool oldest, bool latest)
    {
        //Not implemented need to figure out how to handle ui
        return 1;
    }

    internal static int DowngradeConsoleMode(string[] packages, bool verbose, bool noConfirm, bool oldest, bool latest)
    {
        if (packages.Length is 0 or > 1)
        {
            Console.WriteLine("Error: No packages specified or more than one package specified.");
            return 1;
        }

        RootElevator.EnsureRootExectuion();
        var package = packages[0];
        Console.WriteLine($"Looking for downgrade options for: {package}");

        var manager = new AlpmManager(verbose, false, Configuration.GetConfigurationFilePath());
        manager.InitializeWithSync();
        var versions = SearchArchArchive(package);

        if (versions.Count == 0)
        {
            Console.WriteLine("No versions found in the archive.");
            manager.Dispose();
            return 1;
        }

        string selection;
        if (oldest)
        {
            selection = versions.First();
        }
        else if (latest)
        {
            selection = versions.Last();
        }
        else
        {
            Console.WriteLine("Select a version to downgrade to:");
            for (var i = 0; i < versions.Count; i++)
            {
                Console.WriteLine($"  {i + 1}) {versions[i]}");
            }
            Console.Write("Selection: ");
            var input = Console.ReadLine();
            if (!int.TryParse(input, out var idx) || idx < 1 || idx > versions.Count)
            {
                Console.WriteLine("Invalid selection.");
                manager.Dispose();
                return 1;
            }
            selection = versions[idx - 1];
        }

        Console.WriteLine(selection);

        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = true,
            AutomaticDecompression = System.Net.DecompressionMethods.All,
            MaxAutomaticRedirections = 10,
            PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        };
        var client = new HttpClient(handler);
        client.Timeout = TimeSpan.FromMinutes(15);
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Shelly-ALPM/1.0 (compatible)");

        var fileName = $"{selection}-x86_64.pkg.tar.zst";
        var url = $"{ArchRepo}{package[0]}/{package}/{fileName}";
        var filePath = Path.Combine(Path.GetTempPath(), fileName);

        Console.WriteLine($"Downloading {fileName}...");
        using (var response = client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).Result)
        {
            response.EnsureSuccessStatusCode();
            using var fs = new FileStream(filePath, FileMode.Create, FileAccess.Write, FileShare.None);
            response.Content.ReadAsStream().CopyTo(fs);
        }
        Console.WriteLine($"Downloaded to {filePath}");

        if (!noConfirm)
        {
            Console.WriteLine("Do you want to proceed with the installation? (y/n)");
            var input = Console.ReadLine();
            if (input != "y" && input != "Y")
            {
                Console.WriteLine("Operation cancelled.");
                if (File.Exists(filePath)) File.Delete(filePath);
                manager.Dispose();
                return 0;
            }
        }

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

        try
        {
            Console.WriteLine("Installing package...");
            manager.InstallLocalPackage(filePath);
            if (renderer.HasRows)
                renderer.FinishTable();
            Console.WriteLine("Package downgraded successfully!");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Downgrade failed: {ex.Message}");
            return 1;
        }
        finally
        {
            if (File.Exists(filePath)) File.Delete(filePath);
            manager.Dispose();
        }

        return 0;
    }

    private static List<string> SearchArchArchive(string packageName)
    {
        var htmlRegex = new Regex(
            $"<a href=\"(?<filename>{Regex.Escape(packageName)}-[a-zA-Z0-9._+]+-[0-9]+-[a-zA-Z0-9_]+\\.pkg\\.tar\\.(?:zst|xz))\">",
            RegexOptions.Multiline);
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = true,
            AutomaticDecompression = System.Net.DecompressionMethods.All,
            MaxAutomaticRedirections = 10,
            PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        };
        var client = new HttpClient(handler);
        client.Timeout = TimeSpan.FromMinutes(15);
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Shelly-ALPM/1.0 (compatible)");
        var result = client.GetAsync($"{ArchRepo}{packageName[0]}/{packageName}/").Result;
        var content = result.Content.ReadAsStringAsync().Result;
        var matches = htmlRegex.Matches(content);
        var results = new List<string>();
        foreach (Match match in matches)
        {
            var filename = match.Groups["filename"].Value;
            results.Add(Regex.Replace(filename, "-x86.*", ""));
        }
        client.Dispose();
        return results;
    }
}
