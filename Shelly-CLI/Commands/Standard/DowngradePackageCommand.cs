using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using PackageManager.Alpm;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
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
    private const string CachyosRepo = "https://archive.cachyos.org/archive/cachyos/";
    private const string CachyosV3Repo = "https://archive.cachyos.org/archive/cachyos-v3/";
    private const string CachyosV4Repo = "https://archive.cachyos.org/archive/cachyos-v4/";

    private const string PacmanCache = "/var/cache/pacman/pkg/";

    [GeneratedRegex("[0-9][a-zA-Z0-9._]+")]
    private static partial Regex VersionRegex();

    [GeneratedRegex("([0-9]+(\\.[0-9]+)?|[a-z0-9]{6,})")]
    private static partial Regex ReleaseOrHashRegex();

    public override async Task<int> ExecuteAsync(CommandContext context, DowngradePackageCommandSettings settings)
    {
        if (Program.IsUiMode) return await HandleUiModeDowngradeAsync(settings);

        if (!ValidateSettings(settings)) return 1;

        RootElevator.EnsureRootExectuion();
        using var manager = new AlpmManager();
        manager.Initialize(true, showHiddenPackages: true);

        var installedPackage = manager.GetInstalledPackage(settings.Packages[0]);
        if (installedPackage == null)
        {
            AnsiConsole.MarkupLine("[red]Error: Package must be installed to downgrade.[/]");
            return 1;
        }

        AnsiConsole.MarkupLine($"[yellow]Looking for downgrade options for:[/] {settings.Packages[0].EscapeMarkup()}");

        var packages = await GatherDowngradeOptions(manager, installedPackage);

        if (settings.ListOptions) return ListOptionsCli(packages, settings.JsonOutput);

        if (ResolveSelectionCli(packages, installedPackage, settings) is not { } selection) return 1;

        AnsiConsole.MarkupLine($"Selected: {selection.Filename.EscapeMarkup()}");

        var filePath = await ResolveFilePathCli(selection);
        if (filePath == null) return 1;

        if (!settings.NoConfirm && !AnsiConsole.Confirm("Do you want to proceed with the installation?"))
        {
            AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
            return 0;
        }

        AnsiConsole.MarkupLine("[yellow]Installing package...[/]");

        var isSuccess = await StandardSinglePaneOutput.Output(manager,
            m => m.InstallLocalPackage(filePath), settings.NoConfirm);

        if (selection.Location == Location.Remote && File.Exists(filePath))
            try
            {
                File.Delete(filePath);
            }
            catch (Exception e)
            {
                AnsiConsole.MarkupLine($"[red]Error: Failed to delete temporary file: {e.Message.EscapeMarkup()}[/]");
            }

        if (!isSuccess)
        {
            AnsiConsole.MarkupLine("[red]Downgrade failed. See errors above.[/]");
            return 1;
        }

        if (ConfirmForIgnore(settings))
            try
            {
                AnsiConsole.WriteLine($"Adding {selection.Name} to IgnorePkg list.");
                manager.IgnorePackage(selection.Name);
            }
            catch (Exception e)
            {
                AnsiConsole.MarkupLine($"[red]Error: {e.Message.EscapeMarkup()}[/]");
            }

        AnsiConsole.MarkupLine("[green]Package downgraded successfully![/]");
        return 0;
    }

    private static bool ValidateSettings(DowngradePackageCommandSettings settings)
    {
        if (!string.IsNullOrWhiteSpace(settings.Target) && settings.UseOldest)
        {
            AnsiConsole.MarkupLine("[red]Error: Cannot combine --target with --latest or --oldest.[/]");
            return false;
        }

        if (!string.IsNullOrWhiteSpace(settings.Target) && settings.ListOptions)
        {
            AnsiConsole.MarkupLine("[red]Error: Cannot combine --target with --list-options.[/]");
            return false;
        }

        if (settings.Packages.Length != 1)
        {
            AnsiConsole.MarkupLine("[red]Error: No packages specified or more than one package specified.[/]");
            return false;
        }

        return true;
    }

    private static async Task<List<PackageInfo>> GatherDowngradeOptions(AlpmManager manager, AlpmPackageDto package)
    {
        var packages = SearchLocalCache(package);
        var archivedPackages = await SearchArchives(manager, package);
        packages.AddRange(archivedPackages);
        return SortDowngradeOptions(packages);
    }

    private static PackageInfo? ResolveSelectionCli(
        List<PackageInfo> packages,
        AlpmPackageDto installedPackage,
        DowngradePackageCommandSettings settings)
    {
        if (string.IsNullOrWhiteSpace(settings.Target)) return PromptPackageVersion(settings, packages);

        try
        {
            return MatchPackageToTargetVersion(packages, installedPackage, settings.Target);
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Error: {ex.Message.EscapeMarkup()}[/]");
            return null;
        }
    }

    private static async Task<string?> ResolveFilePathCli(PackageInfo selection)
    {
        try
        {
            return selection.Location switch
            {
                Location.Local => Path.Combine(PacmanCache, selection.Filename),
                Location.Remote => await DownloadRemotePackageCli(selection),
                _ => throw new InvalidOperationException()
            };
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Error: Failed to resolve file path: {ex.Message.EscapeMarkup()}[/]");
            return null;
        }
    }

    private static async Task<string> DownloadRemotePackageCli(PackageInfo packageInfo)
    {
        var path = await AnsiConsole.Status()
            .StartAsync($"[yellow]Downloading {packageInfo.Filename.EscapeMarkup()}...[/]",
                async _ => await FetchRemotePackage(packageInfo));

        AnsiConsole.MarkupLine($"[green]Downloaded to {path.EscapeMarkup()}[/]");
        return path;
    }

    private static int ListOptionsCli(List<PackageInfo> packages, bool jsonOutput)
    {
        if (jsonOutput)
        {
            var json = JsonSerializer.Serialize(packages, ShellyCLIJsonContext.Default.ListPackageInfo);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, Encoding.UTF8);
            writer.WriteLine(json);
            writer.Flush();
            return 0;
        }

        if (packages.Count == 0)
        {
            AnsiConsole.MarkupLine("[red]Error: No downgrade options found.[/]");
            return 1;
        }

        var table = new Table().Border(TableBorder.Rounded);
        table.AddColumn("Filename");
        table.AddColumn("Location");
        table.AddColumn("Installed");

        foreach (var p in packages)
            table.AddRow(
                p.Filename.EscapeMarkup(),
                p.Location.ToString(),
                p.IsInstalled ? "[green]✓[/]" : "");

        AnsiConsole.Write(table);
        return 0;
    }

    private static bool ConfirmForIgnore(DowngradePackageCommandSettings settings)
    {
        return settings.AddIgnore ||
               (!settings.NoConfirm && AnsiConsole.Confirm("Do you want to add package to IgnorePkg list?"));
    }

    private static PackageInfo PromptPackageVersion(
        DowngradePackageCommandSettings settings,
        List<PackageInfo> packageInfos)
    {
        var isAutoSelect = settings.NoConfirm || settings.UseOldest;
        var preSelectedPackage = settings.UseOldest ? packageInfos[^1] : packageInfos[0];

        return isAutoSelect
            ? preSelectedPackage
            : AnsiConsole.Prompt(new SelectionPrompt<PackageInfo>()
                .Title("[yellow]Select Version[/]")
                .UseConverter(info =>
                    $"{info.Filename.EscapeMarkup()} ({info.Location}){(info.IsInstalled ? " [green]Installed[/]" : "")}")
                .EnableSearch()
                .AddChoices(packageInfos));
    }

    private static async Task<int> HandleUiModeDowngradeAsync(DowngradePackageCommandSettings settings)
    {
        if (settings.Packages.Length != 1)
        {
            UiFrames.Error("UI mode downgrade requires exactly one package.");
            return 1;
        }

        using var manager = new AlpmManager();
        manager.Initialize(true, showHiddenPackages: true);

        var package = manager.GetInstalledPackage(settings.Packages[0]);
        if (package == null)
        {
            UiFrames.Error($"Package '{settings.Packages[0]}' is not installed.");
            return 1;
        }

        var packages = await GatherDowngradeOptions(manager, package);

        if (settings.ListOptions)
        {
            var options = packages
                .Select(p => new DowngradeOptionDto(p.Name, p.Filename, p.Location.ToString(), p.IsInstalled))
                .ToList();
            UiFrames.Frame(options);
            return 0;
        }

        if (string.IsNullOrWhiteSpace(settings.Target))
        {
            UiFrames.Error("UI mode downgrade requires --target. Use --list-options to inspect available versions.");
            return 1;
        }

        PackageInfo selection;
        try
        {
            selection = MatchPackageToTargetVersion(packages, package, settings.Target);
        }
        catch (Exception ex)
        {
            UiFrames.Error($"Failed to resolve downgrade target: {ex.Message}");
            return 1;
        }

        string filePath;
        try
        {
            filePath = selection.Location switch
            {
                Location.Local => Path.Combine(PacmanCache, selection.Filename),
                Location.Remote => await FetchRemotePackage(selection),
                _ => throw new InvalidOperationException()
            };
        }
        catch (Exception ex)
        {
            UiFrames.Error($"Failed to download package: {ex.Message}");
            return 1;
        }

        UiFrames.TxStart($"Installing {selection.Name} {selection.Filename}...");

        var isSuccess = await UiModeOutput.Run(manager,
            m => m.InstallLocalPackage(Path.GetFullPath(filePath)));
        if (!isSuccess)
        {
            UiFrames.TxFailed("Downgrade failed.");
            return 1;
        }

        if (selection.Location == Location.Remote && File.Exists(filePath))
            try
            {
                File.Delete(filePath);
            }
            catch
            {
                // TODO: Add debug logging
            }

        if (settings.AddIgnore)
            try
            {
                manager.IgnorePackage(selection.Name);
            }
            catch
            {
                // TODO: Add debug logging
            }

        UiFrames.TxDone("Package downgraded successfully!");
        return 0;
    }

    private static PackageInfo MatchPackageToTargetVersion(
        List<PackageInfo> packages,
        AlpmPackageDto package,
        string target)
    {
        return target.Contains(".pkg.tar.", StringComparison.Ordinal)
            ? ResolveLocalPackage(packages, package, target)
            : ResolveRemotePackage(packages, target);
    }

    private static PackageInfo ResolveLocalPackage(List<PackageInfo> packages, AlpmPackageDto package, string target)
    {
        var localPath = Path.Combine(PacmanCache, target);
        var location = File.Exists(localPath) ? Location.Local : Location.Remote;
        var isInstalled = target.StartsWith($"{package.Name}-{package.Version}", StringComparison.Ordinal);
        var uri = packages.Find(p => p.Filename == target)?.Uri;

        return new PackageInfo(package.Name, target, location, isInstalled, uri);
    }

    private static PackageInfo ResolveRemotePackage(List<PackageInfo> packages, string target)
    {
        var byFilename =
            packages.Find(p => string.Equals(p.Filename, target, StringComparison.Ordinal));
        var byVersion =
            packages.Find(p => string.Equals(ParsePackageVersion(p), target, StringComparison.Ordinal));

        return byFilename
               ?? byVersion
               ?? throw new InvalidOperationException(
                   $"No downgrade option matched '{target}'. Use --list-options to inspect valid targets.");
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

    private static async Task<List<PackageInfo>> SearchArchives(AlpmManager alpmManager, AlpmPackageDto package)
    {
        using var client = CreateHttpClient();

        List<string> archiveUrls = [$"{ArchRepo}{package.Name[0]}/{package.Name}/"];

        if (alpmManager.IsCachyOs)
        {
            archiveUrls.Add(CachyosRepo);
            var architectures = alpmManager.GetAllowedArchitectures();
            if (architectures.Exists(s => s.EndsWith("v4"))) archiveUrls.Add(CachyosV4Repo);
            if (architectures.Exists(s => s.EndsWith("v3"))) archiveUrls.Add(CachyosV3Repo);
        }

        var tasks = archiveUrls
            .Select(async url =>
            {
                try
                {
                    var content = await client.GetStringAsync(url);
                    return (content, url);
                }
                catch
                {
                    // TODO: Add debug logging
                    return (null, url);
                }
            })
            .ToList();

        var results = await Task.WhenAll(tasks);

        var archiveLinkRegex = new Regex($"""<a href="(?<filename>{CreatePackageRegex(package.Name)})".*>""",
            RegexOptions.Multiline);

        return results
            .Where(r => r.content is not null)
            .SelectMany(r => archiveLinkRegex.Matches(r.content!)
                .Select(match => match.Groups["filename"].Value)
                .Where(filename => !filename.EndsWith(".sig"))
                .Select(filename => new PackageInfo(
                    package.Name,
                    filename,
                    Location.Remote,
                    Uri.UnescapeDataString(filename).StartsWith($"{package.Name}-{package.Version}"),
                    $"{r.url}{filename}")))
            .ToList();
    }

    private static async Task<string> FetchRemotePackage(PackageInfo packageInfo)
    {
        using var client = CreateHttpClient();
        var url = packageInfo.Uri ?? $"{ArchRepo}{packageInfo.Name[0]}/{packageInfo.Name}/{packageInfo.Filename}";

        using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();

        var path = Path.Combine(Path.GetTempPath(), packageInfo.Filename);
        await using var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
        await response.Content.CopyToAsync(fs);

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
            .Select(filename => new PackageInfo(
                package.Name,
                filename,
                Location.Local,
                Uri.UnescapeDataString(filename).StartsWith($"{package.Name}-{package.Version}")))
            .ToList();
    }

    private static List<PackageInfo> SortDowngradeOptions(List<PackageInfo> packages)
    {
        var naturalComparer = StringComparer.Create(CultureInfo.InvariantCulture, CompareOptions.NumericOrdering);
        return packages
            .OrderByDescending(info => info.Filename, naturalComparer)
            .ThenByDescending(info => info.IsInstalled)
            .ThenByDescending(info => info.Location)
            .ToList();
    }

    private static HttpClient CreateHttpClient()
    {
        return new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = true,
            AutomaticDecompression = DecompressionMethods.All,
            MaxAutomaticRedirections = 10,
            PooledConnectionLifetime = TimeSpan.FromMinutes(2)
        })
        {
            Timeout = TimeSpan.FromMinutes(15),
            DefaultRequestHeaders = { UserAgent = { Http.UserAgent } }
        };
    }

    private static string CreatePackageRegex(string packageName)
    {
        return $"""{Regex.Escape(packageName)}-{VersionRegex()}-{ReleaseOrHashRegex()}-[^"]+\.pkg\.tar\.[^"]+""";
    }

    public record PackageInfo(
        string Name,
        string Filename,
        Location Location,
        bool IsInstalled,
        string? Uri = null);
}