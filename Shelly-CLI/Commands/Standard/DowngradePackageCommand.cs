using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using PackageManager.Alpm;
using PackageManager.Wire;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public partial class DowngradePackageCommand : AsyncCommand<DowngradePackageCommandSettings>
{
    public enum Location
    {
        Remote,
        Local
    }

    private const string ArchRepo = "https://archive.archlinux.org/packages/";
    private const string PacmanCache = "/var/cache/pacman/pkg/";

    [GeneratedRegex("[a-zA-Z0-9.]+")]
    private static partial Regex VersionRegex();

    [GeneratedRegex("([0-9]+(\\.[0-9]+)?|[a-z0-9]{6,})")]
    private static partial Regex ReleaseOrHashRegex();

    public override async Task<int> ExecuteAsync(CommandContext context, DowngradePackageCommandSettings settings)
    {
        if (Program.IsUiMode) return await HandleUiModeDowngradeAsync(settings);

        if (settings is { UseNewest: true, UseOldest: true })
        {
            AnsiConsole.MarkupLine("[red]Error: Cannot use both --latest and --oldest.[/]");
            return 1;
        }

        if (!string.IsNullOrWhiteSpace(settings.Target) && (settings.UseNewest || settings.UseOldest))
        {
            AnsiConsole.MarkupLine("[red]Error: Cannot combine --target with --latest or --oldest.[/]");
            return 1;
        }

        if (!string.IsNullOrWhiteSpace(settings.Target) && settings.ListOptions)
        {
            AnsiConsole.MarkupLine("[red]Error: Cannot combine --target with --list-options.[/]");
            return 1;
        }

        // TODO: Add support for downgrading multiple packages at once
        if (settings.Packages.Length != 1)
        {
            AnsiConsole.MarkupLine("[red]Error: No packages specified or more than one package specified.[/]");
            return 1;
        }

        if (!settings.JsonOutput)
            AnsiConsole.MarkupLine(
                $"[yellow]Looking for downgrade options for:[/] {settings.Packages[0].EscapeMarkup()}");

        if (settings.ListOptions)
        {
            using var listManager = new AlpmManager();
            listManager.Initialize(true, showHiddenPackages: true);

            var listPackage = listManager.GetInstalledPackage(settings.Packages[0]);
            if (listPackage == null)
            {
                AnsiConsole.MarkupLine("[red]Error: Package must be installed to downgrade.[/]");
                return 1;
            }

            List<PackageInfo> listPackages;
            try
            {
                listPackages = await SearchArchArchive(listPackage);
            }
            catch (Exception ex)
            {
                AnsiConsole.MarkupLine(
                    $"[yellow]Warning: Failed to fetch remote options: {ex.Message.EscapeMarkup()}[/]");
                listPackages = [];
            }

            var localListPackages = SearchLocalCache(listPackage);
            listPackages.AddRange(localListPackages);
            listPackages = SortDowngradeOptions(listPackages);

            if (settings.JsonOutput)
            {
                var json = JsonSerializer.Serialize(listPackages, ShellyCLIJsonContext.Default.ListPackageInfo);
                await using var stdout = Console.OpenStandardOutput();
                await using var writer = new StreamWriter(stdout, Encoding.UTF8);
                await writer.WriteLineAsync(json);
                await writer.FlushAsync();
                return 0;
            }

            if (listPackages.Count == 0)
            {
                AnsiConsole.MarkupLine("[red]Error: No downgrade options found.[/]");
                return 1;
            }

            var table = new Table().Border(TableBorder.Rounded);
            table.AddColumn("Filename");
            table.AddColumn("Location");
            table.AddColumn("Installed");

            foreach (var p in listPackages)
                table.AddRow(
                    p.Filename.EscapeMarkup(),
                    p.Location.ToString(),
                    p.IsInstalled ? "[green]✓[/]" : "");

            AnsiConsole.Write(table);
            return 0;
        }

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

        PackageInfo selection;
        if (!string.IsNullOrWhiteSpace(settings.Target))
        {
            try
            {
                selection = await ResolveTargetSelectionAsync(package, settings.Target);
            }
            catch (Exception ex)
            {
                AnsiConsole.MarkupLine($"[red]Error: {ex.Message.EscapeMarkup()}[/]");
                return 1;
            }
        }
        else
        {
            var packages = await SearchArchArchive(package);
            var localPackages = SearchLocalCache(package);
            packages.AddRange(localPackages);

            if (packages.Count == 0)
            {
                AnsiConsole.MarkupLine("[red]Error: No downgrade options found.[/]");
                return 1;
            }

            packages = SortDowngradeOptions(packages);
            selection = SelectPackageVersion(settings, packages);
        }

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
    }

    private static bool ShouldIgnorePackage(DowngradePackageCommandSettings settings)
    {
        return settings is { NoConfirm: true, AddIgnore: true }
               || settings.AddIgnore
               || AnsiConsole.Confirm("Do you want to add package to IgnorePkg list?");
    }

    private static List<PackageInfo> SortDowngradeOptions(List<PackageInfo> packages)
    {
        var naturalComparer = StringComparer.Create(CultureInfo.InvariantCulture, CompareOptions.NumericOrdering);
        return packages.OrderByDescending(info => info.Filename, naturalComparer)
            .ThenByDescending(info => info.IsInstalled)
            .ThenByDescending(info => info.Location)
            .ToList();
    }

    private static PackageInfo SelectPackageVersion(DowngradePackageCommandSettings settings,
        List<PackageInfo> packageInfos)
    {
        var isAutoSelect = settings.NoConfirm || settings.UseNewest || settings.UseOldest;
        var preSelectedPackage = settings.UseOldest ? packageInfos[^1] : packageInfos[0];

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

    private static async Task<PackageInfo> ResolveTargetSelectionAsync(AlpmPackageDto package, string target)
    {
        if (target.Contains(".pkg.tar.", StringComparison.Ordinal))
        {
            var localPath = Path.Combine(PacmanCache, target);
            var location = File.Exists(localPath) ? Location.Local : Location.Remote;
            var isInstalled = target.StartsWith($"{package.Name}-{package.Version}", StringComparison.Ordinal);
            return new PackageInfo(package.Name, target, location, isInstalled);
        }

        List<PackageInfo> packages;
        Exception? remoteSearchError = null;
        try
        {
            packages = await SearchArchArchive(package);
        }
        catch (Exception ex)
        {
            packages = [];
            remoteSearchError = ex;
        }

        packages.AddRange(SearchLocalCache(package));
        packages = SortDowngradeOptions(packages);

        var match = MatchPackageToTarget(packages, target);
        if (match is { } result) return result;

        if (remoteSearchError != null)
            throw new InvalidOperationException(
                $"Failed to fetch remote downgrade options while resolving '{target}': {remoteSearchError.Message}",
                remoteSearchError);

        throw new InvalidOperationException(
            $"No downgrade option matched '{target}'. Use --list-options to inspect valid targets.");
    }

    private static PackageInfo? MatchPackageToTarget(IEnumerable<PackageInfo> packages, string target)
    {
        foreach (var package in packages)
            if (string.Equals(package.Filename, target, StringComparison.Ordinal))
                return package;

        foreach (var package in packages)
        {
            var version = ParsePackageVersion(package);
            if (!string.Equals(version, target, StringComparison.Ordinal)) continue;
            return package;
        }

        return null;
    }

    private static string? ParsePackageVersion(PackageInfo package)
    {
        var prefix = $"{package.Name}-";
        if (!package.Filename.StartsWith(prefix, StringComparison.Ordinal)) return null;

        var extensionIndex = package.Filename.IndexOf(".pkg.tar.", StringComparison.Ordinal);
        if (extensionIndex < 0) return null;

        var versionAndArch = package.Filename[prefix.Length..extensionIndex];
        var archSeparatorIndex = versionAndArch.LastIndexOf('-');
        return archSeparatorIndex > 0 ? versionAndArch[..archSeparatorIndex] : null;
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

    private static async Task<int> HandleUiModeDowngradeAsync(DowngradePackageCommandSettings settings)
    {
        if (settings.Packages.Length != 1)
        {
            await Console.Error.WriteLineAsync("UI mode downgrade requires exactly one package.");
            return 1;
        }

        if (settings.ListOptions)
        {
            using var manager = new AlpmManager();
            manager.Initialize(true, showHiddenPackages: true);

            var package = manager.GetInstalledPackage(settings.Packages[0]);
            if (package == null)
            {
                await Console.Error.WriteLineAsync($"Package '{settings.Packages[0]}' is not installed.");
                return 1;
            }

            List<PackageInfo> packages;
            try
            {
                packages = await SearchArchArchive(package);
            }
            catch (Exception ex)
            {
                await Console.Error.WriteLineAsync($"Failed to fetch remote downgrade options: {ex.Message}");
                packages = [];
            }

            var localPackages = SearchLocalCache(package);
            packages.AddRange(localPackages);
            packages = SortDowngradeOptions(packages);

            var options = packages
                .Select(p => new DowngradeOptionDto(p.Name, p.Filename, p.Location.ToString(), p.IsInstalled))
                .ToList();

            JsonPackFrame.WriteToStdout(options);
            return 0;
        }

        if (!string.IsNullOrWhiteSpace(settings.Target))
        {
            using var manager = new AlpmManager();
            manager.Initialize(true, showHiddenPackages: true);

            var package = manager.GetInstalledPackage(settings.Packages[0]);
            if (package == null)
            {
                await Console.Error.WriteLineAsync($"Package '{settings.Packages[0]}' is not installed.");
                return 1;
            }

            PackageInfo selection;
            try
            {
                selection = await ResolveTargetSelectionAsync(package, settings.Target);
            }
            catch (Exception ex)
            {
                await Console.Error.WriteLineAsync($"Failed to resolve downgrade target: {ex.Message}");
                return 1;
            }

            string filePath;
            try
            {
                filePath = selection.Location switch
                {
                    Location.Local => Path.Combine(PacmanCache, selection.Filename),
                    Location.Remote => await DownloadRemote(selection),
                    _ => throw new InvalidOperationException()
                };
            }
            catch (Exception ex)
            {
                await Console.Error.WriteLineAsync($"Failed to download package: {ex.Message}");
                return 1;
            }

            var isSuccess = await StandardSinglePaneOutput.Output(manager, m => m.InstallLocalPackage(filePath), true);

            if (selection.Location == Location.Remote && File.Exists(filePath))
                File.Delete(filePath);

            if (!isSuccess)
            {
                await Console.Error.WriteLineAsync("Downgrade failed.");
                return 1;
            }

            if (settings.AddIgnore)
                try
                {
                    manager.IgnorePackage(selection.Name);
                }
                catch (Exception ex)
                {
                    await Console.Error.WriteLineAsync($"Failed to add package to IgnorePkg: {ex.Message}");
                }

            return 0;
        }

        return 1;
    }

    public record struct PackageInfo(string Name, string Filename, Location Location, bool IsInstalled);
}