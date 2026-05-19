using System.Text.RegularExpressions;
using PackageManager.Alpm;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class DowngradePackageCommand : Command<DowngradePackageCommandSettings>
{
    private const string cachyRepo = "https://archive.cachyos.org/repo/";
    private const string archRepo = "https://archive.archlinux.org/packages/";
    private const string pacmanCache = "/var/cache/pacman/pkg/";

    //TODO: IMPLEMENT TO HANDLE ADDITIONAL REPOS OTHER THAN JUST ARCH AND LOCAL PACKAGES
    public override int Execute(CommandContext context, DowngradePackageCommandSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeDowngrade(settings);
        }

        if (settings.Packages.Length is 0 or > 1)
        {
            AnsiConsole.MarkupLine("[red]Error: No packages specified or more than one package specified.[/]");
            return 1;
        }

        RootElevator.EnsureRootExectuion();
        var package = settings.Packages[0];
        AnsiConsole.MarkupLine($"[yellow]Looking for downgrade options for:[/]: {package.EscapeMarkup()}");

        var manager = new AlpmManager();
        manager.Initialize(true);
        var packages = SearchArchArchive(package);
        string selection;
        if (!settings.NoConfirm)
        {
            selection = AnsiConsole.Prompt(
                new SelectionPrompt<string>()
                    .Title($"[yellow]Select Version[/]")
                    .AddChoices(packages));
            AnsiConsole.WriteLine(selection);
        }
        else
        {
            selection = packages.First();
        }

        //"-x86_64.pkg.tar.zst";
        var handler = new SocketsHttpHandler()
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
        var url = $"{archRepo}{package[0]}/{package}/{fileName}";

        var filePath = Path.Combine(Path.GetTempPath(), fileName);

        AnsiConsole.Status()
            .Start($"[yellow]Downloading {fileName.EscapeMarkup()}...[/]", ctx =>
            {
                using var response = client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).Result;
                response.EnsureSuccessStatusCode();

                using var fs = new FileStream(filePath, FileMode.Create, FileAccess.Write, FileShare.None);
                response.Content.ReadAsStream().CopyTo(fs);
            });

        AnsiConsole.MarkupLine($"[green]Downloaded to {filePath.EscapeMarkup()}[/]");

        if (!settings.NoConfirm)
        {
            if (!AnsiConsole.Confirm("Do you want to proceed with the installation?"))
            {
                AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
                return 0;
            }
        }

        var renderLock = new object();
        manager.Question += (sender, args) =>
        {
            lock (renderLock)
            {
                AnsiConsole.WriteLine();
                QuestionHandler.HandleQuestion(args, Program.IsUiMode, settings.NoConfirm);
            }
        };
        int currentPkgIndex = 0;
        int totalPkgs = 1;
        string? lastPackageName = null;
        int lastPercent = 0;
        manager.Progress += (sender, args) =>
        {
            lock (renderLock)
            {
                var name = args.PackageName ?? "unknown";
                var pct = args.Percent ?? 0;
                var bar = string.Join("", Enumerable.Repeat("🐚 ", pct * 2 / 5)) + new string('░', 20 - pct / 5);
                var actionType = args.ProgressType;

                // Detect package change
                if (name != lastPackageName)
                {
                    // If this isn't the first package, complete the previous line
                    if (lastPackageName != null)
                    {
                        Console.WriteLine(); // Move to new line
                        currentPkgIndex++;
                    }

                    lastPackageName = name;
                    lastPercent = 0;
                }

                // Update current line with carriage return
                Console.Write(
                    $"\r({currentPkgIndex + 1}/{totalPkgs}) installing {name,-40}  [{bar}] {pct,3}% - {actionType,-20}");

                lastPercent = pct;
            }
        };

        bool hadError = false;
        manager.ErrorEvent += (_, e) =>
        {
            lock (renderLock)
            {
                AnsiConsole.MarkupLine($"[red]ERROR: {e.Error.EscapeMarkup()}[/]");
            }

            hadError = true;
        };

        AnsiConsole.MarkupLine("[yellow]Installing package...[/]");
        var result = manager.InstallLocalPackage(filePath).Result;

        if (File.Exists(filePath))
        {
            File.Delete(filePath);
        }

        manager.Dispose();

        if (!result || hadError)
        {
            AnsiConsole.MarkupLine("[red]Downgrade failed. See errors above.[/]");
            return 1;
        }

        AnsiConsole.MarkupLine("[green]Package downgraded successfully![/]");
        return 0;
    }

    private static int HandleUiModeDowngrade(DowngradePackageCommandSettings settings)
    {
        //Not implemented need to figure out how to handle ui
        return 1;
    }

    private string GetOperatingSystem()
    {
        var lines = File.ReadAllLines("/etc/os-release");
        var osDictionary = lines.Select(x => x.Split('=')).ToDictionary(y => y[0], y => y[1]);
        return osDictionary.GetValueOrDefault("PRETTY_NAME", "ArchLinux");
    }

    private List<string> SearchArchArchive(string packageName)
    {
        var htmlRegex =
            new Regex(
                $"<a href=\"(?<filename>{Regex.Escape(packageName)}-[a-zA-Z0-9._+]+-[0-9]+-[a-zA-Z0-9_]+\\.pkg\\.tar\\.(?:zst|gz))\">",
                RegexOptions.Multiline);

        var handler = new SocketsHttpHandler()
        {
            AllowAutoRedirect = true,
            AutomaticDecompression = System.Net.DecompressionMethods.All,
            MaxAutomaticRedirections = 10,
            PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        };
        var client = new HttpClient(handler);
        client.Timeout = TimeSpan.FromMinutes(15);
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Shelly-ALPM/1.0 (compatible)");
        var result = client.GetAsync($"{archRepo}{packageName[0]}/{packageName}/").Result;
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

    private string SearchCachyArchive(string packageName)
    {
        return string.Empty;
    }

    private List<string> SearchLocalCache(string packageName)
    {
        var versionRegex = new Regex("[a-zA-Z0-9.]+");
        var hashOrMinor = new Regex("([0-9]+|[a-z0-9]{6,})");
        var files = Directory.GetFiles(pacmanCache)
            .Where(x => Regex.IsMatch(Path.GetFileName(x),
                $"^{Regex.Escape(packageName)}-{versionRegex.ToString()}-{hashOrMinor.ToString()}-.*\\.pkg\\.tar\\..*"))
            .Select(x => Regex.Replace(Path.GetFileName(x), "-x86.*", ""))
            .ToList();

        return files;
    }
}