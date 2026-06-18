using System.CommandLine;
using System.Net;
using PackageManager.Alpm;
using PackageManager.Local;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using Shelly.Utilities;
using static System.CommandLine.ArgumentArity;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Standard;

public class Install : GlobalSettingsCommand
{
    private bool BuildDeps { get; set; }

    private bool MakeDeps { get; set; }

    private bool NoDeps { get; set; }

    private bool Upgrade { get; set; }

    private string[] Packages { get; set; } = [];

    public static Command Create()
    {
        var buildDeps = new Option<bool>("--build-deps", "-b") { Description = "Install build dependencies" };
        var makeDeps = new Option<bool>("--make-deps", "-m") { Description = "Install make dependencies" };
        var noDeps = new Option<bool>("--no-deps", "-d") { Description = "Install without checking/installing dependencies" };
        var upgrade = new Option<bool>("--upgrade", "-u") { Description = "Upgrades the packages if they are already installed" };
        var packages = new Argument<string[]>("packages")
            { Description = "The packages to install (repo names, local files or URLs)", Arity = ZeroOrMore };

        var command = new Command("install", "Install packages")
        {
            buildDeps, makeDeps, noDeps, upgrade, packages
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Install
            {
                BuildDeps = parseResult.GetValue(buildDeps),
                MakeDeps = parseResult.GetValue(makeDeps),
                NoDeps = parseResult.GetValue(noDeps),
                Upgrade = parseResult.GetValue(upgrade),
                Packages = parseResult.GetValue(packages) ?? []
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        if (Packages.Length == 0)
        {
            console.WriteLine(Colorize("Error: No packages specified", ConsoleColor.Red));
            return;
        }

        RootElevator.EnsureRootExectuion();

        var names = new List<string>();
        var files = new List<string>();

        foreach (var entry in Packages)
            switch (Classify(entry))
            {
                case PackageSourceKind.Url:
                    var downloaded = await DownloadToTempFile(entry, console);
                    if (downloaded is not null)
                        files.Add(downloaded);
                    break;
                case PackageSourceKind.PackageName:
                    names.Add(entry);
                    break;
                case PackageSourceKind.FilePath:
                    files.Add(entry);
                    break;
            }

        if (names.Count > 0)
            await InstallRepoPackages(names, console);

        foreach (var file in files)
            await InstallLocalPackage(file, console);
    }

    private async Task InstallRepoPackages(List<string> packageList, IShellyConsole console)
    {
        console.WriteLine(Colorize($"Packages to install: {string.Join(", ", packageList)}", ConsoleColor.Yellow));

        if (!NoConfirm && !Confirm.Execute("Do you want to proceed?"))
        {
            console.WriteLine(Colorize("Operation cancelled.", ConsoleColor.Yellow));
            return;
        }

        using var manager = new AlpmManager();
        console.WriteLine(Colorize("Initializing ALPM...", ConsoleColor.Yellow));
        manager.Initialize(true);

        if (Upgrade)
        {
            console.WriteLine(Colorize("Running system upgrade", ConsoleColor.Yellow));
            if (!await RunOutput(x => x.SyncSystemUpdate()))
            {
                console.WriteLine(Colorize("System upgrade failed. See errors above.", ConsoleColor.Red));
                return;
            }
        }

        if (BuildDeps)
        {
            if (packageList.Count > 1)
            {
                console.WriteLine(Colorize("Cannot build dependencies for multiple packages at once.", ConsoleColor.Yellow));
                return;
            }

            console.WriteLine(Colorize("Installing packages...", ConsoleColor.Yellow));
            var depsResult = await RunOutput(x => x.InstallDependenciesOnly(packageList[0], MakeDeps));
            if (!depsResult)
            {
                console.WriteLine(Colorize("Installation failed. See errors above.", ConsoleColor.Red));
                return;
            }

            console.WriteLine(Colorize("Packages installed successfully!", ConsoleColor.Green));
            return;
        }

        if (NoDeps)
        {
            console.WriteLine(Colorize("Skipping dependency installation.", ConsoleColor.Yellow));
            console.WriteLine(Colorize("Installing packages...", ConsoleColor.Yellow));
            if (!await RunOutput(x => x.InstallPackages(packageList, AlpmTransFlag.NoDeps)))
            {
                console.WriteLine(Colorize("Installation failed. See errors above.", ConsoleColor.Red));
                return;
            }

            console.WriteLine(Colorize("Packages installed successfully!", ConsoleColor.Green));
            return;
        }

        console.WriteLine(Colorize("Installing packages...", ConsoleColor.Yellow));
        var installResult = await RunOutput(x => x.InstallPackages(packageList));
        console.WriteLine();
        if (!installResult)
        {
            console.WriteLine(Colorize("Installation failed. See errors above.", ConsoleColor.Red));
            return;
        }

        console.WriteLine(Colorize("Packages installed successfully!", ConsoleColor.Green));

        return;

        Task<bool> RunOutput(Func<IAlpmManager, Task<bool>> op)
        {
            return StandardSinglePaneOutput.Output(console, manager, op, NoConfirm);
        }
    }

    private async Task InstallLocalPackage(string location, IShellyConsole console)
    {
        if (!File.Exists(location))
        {
            console.WriteLine(Colorize($"Error: Specified file does not exist: {location}", ConsoleColor.Red));
            return;
        }

        if (await FileInspector.IsArchPackage(location))
        {
            using var manager = new AlpmManager();
            console.WriteLine(Colorize("Initializing ALPM...", ConsoleColor.Yellow));
            manager.Initialize();
            var result = await StandardSinglePaneOutput.Output(console, manager,
                x => x.InstallLocalPackage(Path.GetFullPath(location)), NoConfirm);
            if (!result)
                console.WriteLine(Colorize("Installation failed. See errors above.", ConsoleColor.Red));
            return;
        }

        if (await FileInspector.IsBinariesPackage(location))
        {
            var localManager = new LocalManager();
            localManager.Message += (_, e) =>
            {
                var color = e.Level switch
                {
                    LocalManagerMessageLevel.Info => ConsoleColor.Cyan,
                    LocalManagerMessageLevel.Warning => ConsoleColor.Yellow,
                    LocalManagerMessageLevel.Error => ConsoleColor.Red,
                    LocalManagerMessageLevel.Success => ConsoleColor.Green,
                    _ => ConsoleColor.White
                };
                console.WriteLine(Colorize(e.Message, color));
            };

            await localManager.InstallBinariesPackage(Path.GetFullPath(location));
            return;
        }

        console.WriteLine(Colorize("Error: Unsupported local package format.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Packages.Length == 0)
        {
            UiFrames.Error("No packages specified");
            return;
        }

        var names = new List<string>();
        var files = new List<string>();

        foreach (var entry in Packages)
            switch (Classify(entry))
            {
                case PackageSourceKind.Url:
                    var downloaded = await DownloadToTempFileUi(entry);
                    if (downloaded is not null)
                        files.Add(downloaded);
                    break;
                case PackageSourceKind.PackageName:
                case PackageSourceKind.FilePath:
                    files.Add(entry);
                    break;
            }

        if (names.Count > 0)
            await InstallRepoPackagesUi(names);

        foreach (var file in files)
            await InstallLocalPackageUi(file);
    }

    private async Task InstallRepoPackagesUi(List<string> packageList)
    {
        using var manager = new AlpmManager();
        manager.Initialize(true);
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);

        if (Upgrade)
        {
            UiFrames.TxStart("Running system upgrade...");
            var upgradeOk = await UiModeOutput.Run(manager, m => m.SyncSystemUpdate());
            if (!upgradeOk)
            {
                UiFrames.TxFailed("System upgrade failed.");
                return;
            }
        }

        if (BuildDeps)
        {
            if (packageList.Count > 1)
            {
                UiFrames.Error("Cannot build dependencies for multiple packages at once.");
                return;
            }

            UiFrames.TxStart(MakeDeps
                ? "Installing dependencies (including make dependencies)..."
                : "Installing dependencies...");
            var depsOk = await UiModeOutput.Run(manager, m => m.InstallDependenciesOnly(packageList[0], MakeDeps));
            UiFrames.TxFinish(depsOk, "Dependencies installed successfully!", "Dependency installation failed.");
            return;
        }

        var flags = NoDeps ? AlpmTransFlag.NoDeps : AlpmTransFlag.None;
        UiFrames.TxStart($"Installing packages: {string.Join(", ", packageList)}");
        var ok = await UiModeOutput.Run(manager, m => m.InstallPackages(packageList, flags));
        UiFrames.TxFinish(ok, "Packages installed successfully!", "Installation failed.");
    }

    private async Task InstallLocalPackageUi(string location)
    {
        if (!File.Exists(location))
        {
            UiFrames.Error($"Specified file does not exist: {location}");
            return;
        }

        if (await FileInspector.IsArchPackage(location))
        {
            using var manager = new AlpmManager();
            manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);
            manager.Initialize();

            UiFrames.TxStart($"Installing local package: {location}");
            var ok = await UiModeOutput.Run(manager, m => m.InstallLocalPackage(Path.GetFullPath(location)));
            UiFrames.TxFinish(ok, "Installation complete.", "Installation failed.");
            return;
        }

        if (await FileInspector.IsBinariesPackage(location))
        {
            var localManager = new LocalManager();
            localManager.Message += (_, e) =>
            {
                switch (e.Level)
                {
                    case LocalManagerMessageLevel.Info:
                    case LocalManagerMessageLevel.Success:
                        UiFrames.Info(e.Message);
                        break;
                    case LocalManagerMessageLevel.Warning:
                        UiFrames.Info($"Warning: {e.Message}");
                        break;
                    case LocalManagerMessageLevel.Error:
                        UiFrames.Error(e.Message);
                        break;
                }
            };

            await localManager.InstallBinariesPackage(Path.GetFullPath(location));
            return;
        }

        UiFrames.Error("Unsupported local package format.");
    }

    private static async Task<string?> DownloadToTempFile(string url, IShellyConsole console)
    {
        try
        {
            console.WriteLine(Colorize($"Downloading {url}...", ConsoleColor.Yellow));
            return await DownloadCore(url);
        }
        catch (Exception ex)
        {
            console.WriteLine(Colorize($"Error: Failed to download {url}: {ex.Message}", ConsoleColor.Red));
            return null;
        }
    }

    private static async Task<string?> DownloadToTempFileUi(string url)
    {
        try
        {
            UiFrames.Info($"Downloading {url}...");
            return await DownloadCore(url);
        }
        catch (Exception ex)
        {
            UiFrames.Error($"Failed to download {url}: {ex.Message}");
            return null;
        }
    }

    private static async Task<string> DownloadCore(string url)
    {
        using var client = CreateHttpClient();
        var fileName = Path.GetFileName(new Uri(url).LocalPath);
        if (string.IsNullOrWhiteSpace(fileName))
            fileName = Path.GetRandomFileName();
        var tempPath = Path.Combine(Path.GetTempPath(), fileName);

        await using var response = await client.GetStreamAsync(url);
        await using var fileStream = File.Create(tempPath);
        await response.CopyToAsync(fileStream);
        return tempPath;
    }

    private static PackageSourceKind Classify(string value)
    {
        if (IsUrl(value)) return PackageSourceKind.Url;

        return IsFilePath(value)
            ? PackageSourceKind.FilePath
            : PackageSourceKind.PackageName;
    }

    private static bool IsUrl(string value)
    {
        return Uri.TryCreate(value, UriKind.Absolute, out var uri)
               && (uri.Scheme == Uri.UriSchemeHttp
                   || uri.Scheme == Uri.UriSchemeHttps
                   || uri.Scheme == Uri.UriSchemeFtp);
    }

    private static bool IsFilePath(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return false;

        if (IsUrl(value)) return false;

        if (value.Contains(Path.DirectorySeparatorChar)
            || value.Contains(Path.AltDirectorySeparatorChar)
            || value.StartsWith('~')
            || Path.IsPathRooted(value))
            return true;

        return Path.HasExtension(value);
    }

    private static HttpClient CreateHttpClient()
    {
        return new HttpClient(new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            AllowAutoRedirect = true,
            MaxAutomaticRedirections = 10,
            ConnectTimeout = TimeSpan.FromSeconds(10),
            EnableMultipleHttp2Connections = true,
            EnableMultipleHttp3Connections = true
        })
        {
            Timeout = TimeSpan.FromSeconds(10),
            DefaultRequestHeaders = { UserAgent = { Http.UserAgent } },
            DefaultRequestVersion = HttpVersion.Version11,
            DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrHigher
        };
    }

    private enum PackageSourceKind
    {
        Url,
        FilePath,
        PackageName
    }
}