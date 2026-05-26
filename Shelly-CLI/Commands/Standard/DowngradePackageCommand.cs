using System.Globalization;
using System.Net;
using System.Text.RegularExpressions;
using PackageManager.Alpm;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public partial class DowngradePackageCommand : AsyncCommand<DowngradePackageCommandSettings>
{
    private const string ArchRepo = "https://archive.archlinux.org/packages/";
    private const string PacmanCache = "/var/cache/pacman/pkg/";

    [GeneratedRegex("[a-zA-Z0-9.]+")]
    private static partial Regex VersionRegex();

    [GeneratedRegex("([0-9]+(\\.[0-9]+)?|[a-z0-9]{6,})")]
    private static partial Regex ReleaseOrHashRegex();

    public override async Task<int> ExecuteAsync(CommandContext context, DowngradePackageCommandSettings settings)
    {
        if (Program.IsUiMode) return HandleUiModeDowngrade(settings);

        if (settings is { UseNewest: true, UseOldest: true })
        {
            AnsiConsole.MarkupLine("[red]Error: Cannot use both --use-newest and --use-oldest.[/]");
            return 1;
        }

        // TODO: Add support for downgrading multiple packages at once
        if (settings.Packages.Length is 0 or > 1)
        {
            AnsiConsole.MarkupLine("[red]Error: No packages specified or more than one package specified.[/]");
            return 1;
        }

        AnsiConsole.MarkupLine($"[yellow]Looking for downgrade options for:[/] {settings.Packages[0].EscapeMarkup()}");

        RootElevator.EnsureRootExectuion();

        using var manager = new AlpmManager();
        manager.Initialize(true, showHiddenPackages: true);

        // TODO: Add version matching: downgrade 'foo=1.0.0-1' 'bar>=1.2.1-1' 'baz=~^1.2',
        //  which allows the use of the following operators:
        //  =,  ==,  =~, <=, >=, < and >.
        //  Note that =~ represents a regex match operator and = and == are aliases.

        var package = manager.GetInstalledPackage(settings.Packages[0]);
        if (package == null)
        {
            AnsiConsole.MarkupLine("[red]Error: Package must be installed to downgrade.[/]");
            return 1;
        }

        var packages = await SearchArchArchive(package);
        var localPackages = SearchLocalCache(package);
        packages.AddRange(localPackages);

        if (packages.Count == 0)
        {
            AnsiConsole.MarkupLine("[red]Error: No downgrade options found.[/]");
            return 1;
        }

        packages = SortDowngradeOptions(packages);

        var selection = SelectPackageVersion(settings, packages);

        AnsiConsole.MarkupLine($"Selected: {selection.Filename.EscapeMarkup()}");

        var filePath = selection.Location switch
        {
            Location.Local => Path.Combine(PacmanCache, selection.Filename),
            Location.Remote => await DownloadRemoteCli(selection),
            _ => throw new InvalidOperationException()
        };

        if (!settings.NoConfirm && !AnsiConsole.Confirm("Do you want to proceed with the installation?"))
        {
            AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
            return 0;
        }

        AnsiConsole.MarkupLine("[yellow]Installing package...[/]");

        var cfg = ConfigManager.ReadConfig();
        var useSinglePane = settings.SinglePane
                            || string.Equals(cfg.OutputMode, "singlepane", StringComparison.OrdinalIgnoreCase)
                            || Console.IsOutputRedirected;
        var isSuccess = useSinglePane
            ? await StandardSinglePaneOutput.Output(manager, m => m.InstallLocalPackage(filePath), settings.NoConfirm)
            : await SplitOutput.Output(manager, m => m.InstallLocalPackage(filePath), settings.NoConfirm);

        if (selection.Location == Location.Remote && File.Exists(filePath)) File.Delete(filePath);

        if (!isSuccess)
        {
            AnsiConsole.MarkupLine("[red]Downgrade failed. See errors above.[/]");
            return 1;
        }

        if (ShouldIgnorePackage(settings))
            try
            {
                manager.IgnorePackage(selection.Name);
                AnsiConsole.WriteLine("Package added to IgnorePkg list.");
            }
            catch (Exception e)
            {
                AnsiConsole.MarkupLine($"[red]Error: {e.Message.EscapeMarkup()}[/]");
                return 1;
            }

        AnsiConsole.MarkupLine("[green]Package downgraded successfully![/]");
        return 0;

        static bool ShouldIgnorePackage(DowngradePackageCommandSettings settings)
        {
            return settings is { NoConfirm: true, AddIgnore: true }
                   || settings.AddIgnore
                   || AnsiConsole.Confirm("Do you want to add package to IgnorePkg list?");
        }

        PackageInfo SelectPackageVersion(DowngradePackageCommandSettings downgradePackageCommandSettings,
            List<PackageInfo> packageInfos)
        {
            var isAutoSelect = downgradePackageCommandSettings.NoConfirm || downgradePackageCommandSettings.UseNewest ||
                               downgradePackageCommandSettings.UseOldest;
            var preSelectedPackage = downgradePackageCommandSettings.UseOldest ? packageInfos[^1] : packageInfos[0];

            return isAutoSelect
                ? preSelectedPackage
                : AnsiConsole.Prompt(
                    new SelectionPrompt<PackageInfo>()
                        .Title("[yellow]Select Version[/]")
                        .UseConverter(info =>
                            $"{info.Filename.EscapeMarkup()} ({info.Location}){(info.IsInstalled ? " [green]Installed[/]" : "")}")
                        .EnableSearch()
                        .AddChoices(packageInfos));
        }
    }

    private static List<PackageInfo> SortDowngradeOptions(List<PackageInfo> packages)
    {
        var naturalComparer = StringComparer.Create(CultureInfo.InvariantCulture, CompareOptions.NumericOrdering);
        return packages.OrderByDescending(info => info.Filename, naturalComparer)
            .ThenByDescending(info => info.IsInstalled)
            .ThenByDescending(info => info.Location)
            .ToList();
    }

    private static async Task<List<PackageInfo>> SearchArchArchive(AlpmPackageDto package)
    {
        using var client = CreateHttpClient();
        using var result = await client.GetAsync($"{ArchRepo}{package.Name[0]}/{package.Name}/");
        result.EnsureSuccessStatusCode();

        var content = await result.Content.ReadAsStringAsync();

        var archiveLinkRegex = new Regex($"""<a href="(?<filename>{CreatePackageRegex(package.Name)})">""",
            RegexOptions.Multiline);

        return archiveLinkRegex.Matches(content)
            .Select(match => match.Groups["filename"].Value)
            .Where(filename => !filename.EndsWith(".sig"))
            .Select(filename => new PackageInfo(package.Name, filename, Location.Remote,
                filename.StartsWith($"{package.Name}-{package.Version}")))
            .ToList();
    }

    private static async Task<string> DownloadRemoteCli(PackageInfo packageInfo)
    {
        var path = await AnsiConsole.Status()
            .StartAsync($"[yellow]Downloading {$"{packageInfo.Filename}".EscapeMarkup()}...[/]",
                async _ => await DownloadRemote(packageInfo));

        AnsiConsole.MarkupLine($"[green]Downloaded to {path.EscapeMarkup()}[/]");
        return path;
    }

    private static List<PackageInfo> SearchLocalCache(AlpmPackageDto package)
    {
        if (!Directory.Exists(PacmanCache)) return [];

        var packageRegex = new Regex($"^{CreatePackageRegex(package.Name)}$");

        return Directory.GetFiles(PacmanCache)
            .Where(filePath => !filePath.EndsWith(".sig"))
            .Select(filePath => Path.GetFileName(filePath))
            .Where(filename => packageRegex.IsMatch(filename))
            .Select(filename =>
                new PackageInfo(package.Name, filename, Location.Local,
                    filename.StartsWith($"{package.Name}-{package.Version}")))
            .ToList();
    }

    private static async Task<string> DownloadRemote(PackageInfo packageInfo)
    {
        using var client = CreateHttpClient();
        var url = $"{ArchRepo}{packageInfo.Name[0]}/{packageInfo.Name}/{packageInfo.Filename}";

        using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();

        var path = Path.Combine(Path.GetTempPath(), $"{packageInfo.Filename}");
        await using var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
        await response.Content.CopyToAsync(fs);

        return path;
    }

    private static HttpClient CreateHttpClient()
    {
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = true,
            AutomaticDecompression = DecompressionMethods.All,
            MaxAutomaticRedirections = 10,
            PooledConnectionLifetime = TimeSpan.FromMinutes(2)
        };

        var client = new HttpClient(handler);
        client.Timeout = TimeSpan.FromMinutes(15);
        client.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);
        return client;
    }

    private static string CreatePackageRegex(string packageName)
    {
        return $@"{Regex.Escape(packageName)}-{VersionRegex()}-{ReleaseOrHashRegex()}-.*\.pkg\.tar\..*";
    }

    private static int HandleUiModeDowngrade(DowngradePackageCommandSettings settings)
    {
        //Not implemented need to figure out how to handle ui
        return 1;
    }

    private record struct PackageInfo(string Name, string Filename, Location Location, bool IsInstalled);

    private enum Location
    {
        Remote,
        Local
    }
}