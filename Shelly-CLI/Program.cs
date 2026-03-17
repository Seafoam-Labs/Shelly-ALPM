using System.Reflection;
using System.Text.Json;
using Shelly_CLI.Commands.Aur;
using Shelly_CLI.Commands.Flatpak;
using Shelly_CLI.Commands.Keyring;
using Shelly_CLI.Commands.Standard;
using Shelly_CLI.Commands.Utility;
using Shelly_CLI.Configuration;
using Shelly.Writers;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI;

public class Program
{
    public static bool IsUiMode { get; private set; }

    public static int Main(string[] args)
    {
        // Ensure default configuration exists in ~/.config/shelly/config.json
        string configPath;
        if (Environment.GetEnvironmentVariable("USER") == "root")
        {
            var username = Environment.GetEnvironmentVariable("SUDO_USER");
            configPath = Path.Combine("/home", username, ".config", "shelly", "config.json");
        }
        else
        {
            configPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "shelly", "config.json");
        }

        if (!File.Exists(configPath))
        {
            var configDir = Path.GetDirectoryName(configPath);
            if (!string.IsNullOrEmpty(configDir))
            {
                Directory.CreateDirectory(configDir);
            }

            var defaultConfig = new ShellyConfig();
            var options = new JsonSerializerOptions { WriteIndented = true };
            var json = JsonSerializer.Serialize(defaultConfig, typeof(ShellyConfig), new ShellyCLIJsonContext(options));
            File.WriteAllText(configPath, json);
        }

        // Check if running in UI mode (--ui-mode flag passed by Shelly-UI)
        var argsList = args.ToList();
        IsUiMode = argsList.Remove("--ui-mode");
        args = argsList.ToArray();

        if (IsUiMode)
        {
            // Configure stderr to use prefix for UI integration
            var stderrWriter = new StderrPrefixWriter(Console.Error);
            Console.SetError(stderrWriter);

            // Configure AnsiConsole to use DualOutputWriter for UI integration
            var dualWriter = new DualOutputWriter(Console.Out, stderrWriter);
            Console.SetOut(dualWriter);
            AnsiConsole.Console = AnsiConsole.Create(new AnsiConsoleSettings
            {
                Out = new AnsiConsoleOutput(dualWriter)
            });
        }
        else
        {
            // When running from terminal, filter out lines containing [bracketed] patterns
            var filteringStdout = new FilteringTextWriter(Console.Out);
            var filteringStderr = new FilteringTextWriter(Console.Error);
            Console.SetOut(filteringStdout);
            Console.SetError(filteringStderr);
            AnsiConsole.Console = AnsiConsole.Create(new AnsiConsoleSettings
            {
                Out = new AnsiConsoleOutput(filteringStdout)
            });
        }

        var app = new CommandApp();
        app.SetDefaultCommand<Commands.DefaultCommand>();
        app.Configure(config =>
        {
            config.SetApplicationName("shelly");
            config.SetApplicationVersion(Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "unknown");

            config.AddCommand<VersionCommand>("version")
                .WithDescription("Display the application version")
                .WithExample("version");

            config.AddCommand<SyncCommand>("sync")
                .WithDescription("Synchronize package databases")
                .WithExample("sync");

            config.AddCommand<ListInstalledCommand>("list-installed")
                .WithDescription("List all installed packages")
                .WithExample("list-installed")
                .WithExample("list-installed", "--sort", "name")
                .WithExample("list-installed", "--sort", "size")
                .WithExample("list-installed", "--sort", "size", "--order", "desc")
                .WithExample("list-installed", "--filter", "linux");

            config.AddCommand<ListAvailableCommand>("list-available")
                .WithDescription("List all available packages")
                .WithExample("list-available")
                .WithExample("list-available", "--sort", "name")
                .WithExample("list-available", "--sort", "size")
                .WithExample("list-available", "--sort", "size", "--order", "desc")
                .WithExample("list-available", "--filter", "firefox");

            config.AddCommand<ListUpdatesCommand>("list-updates")
                .WithDescription("List packages that need updates")
                .WithExample("list-updates");

            config.AddCommand<ListReposCommand>("list-repos")
                .WithDescription("List configured repositories in order")
                .WithExample("list-repos");

            config.AddCommand<PackageInformationCommand>("info")
                .WithDescription("Display information about a package")
                .WithExample("info", "firefox", "--installed")
                .WithExample("info", "firefox", "--repository")
                .WithExample("info", "firefox", "-i")
                .WithExample("info", "firefox", "-r");

            config.AddCommand<InstallCommand>("install")
                .WithDescription("Install one or more packages")
                .WithExample("install", "firefox")
                .WithExample("install", "firefox", "vlc", "gimp")
                .WithExample("install", "firefox", "--no-confirm")
                .WithExample("install", "firefox", "--build-deps")
                .WithExample("install", "firefox", "-o")
                .WithExample("install", "firefox", "--make-deps")
                .WithExample("install", "firefox", "-m")
                .WithExample("install", "firefox", "--build-deps", "--make-deps")
                .WithExample("install", "firefox", "-o", "-m")
                .WithExample("install", "firefox", "--no-deps")
                .WithExample("install", "firefox", "-d");

            config.AddCommand<InstallLocalPackageCommand>("install-local")
                .WithDescription("Install a local package file (.xz, .gz, .zst)")
                .WithExample("install-local", "--location", "/path/to/package.pkg.tar.zst")
                .WithExample("install-local", "-l", "/path/to/package.pkg.tar.zst")
                .WithExample("install-local", "--location", "/path/to/package.pkg.tar.xz")
                .WithExample("install-local", "-l", "/path/to/package.pkg.tar.xz")
                .WithExample("install-local", "--location", "/path/to/package.pkg.tar.gz")
                .WithExample("install-local", "-l", "/path/to/package.pkg.tar.gz")
                .WithExample("install-local", "--location", "/path/to/package.pkg.tar.zst", "--no-confirm")
                .WithExample("install-local", "-l", "/path/to/package.pkg.tar.zst", "-n")
                .WithExample("install-local", "--location", "/path/to/package.pkg.tar.xz", "--no-confirm")
                .WithExample("install-local", "-l", "/path/to/package.pkg.tar.xz", "-n")
                .WithExample("install-local", "--location", "/path/to/package.pkg.tar.gz", "--no-confirm")
                .WithExample("install-local", "-l", "/path/to/package.pkg.tar.gz", "-n");

            config.AddCommand<AppImageInstallCommand>("install-appimage")
                .WithDescription("Install an appimage file")
                .WithExample("install-local", "--location", "/path/to/package.pkg.tar.zst")
                .WithExample("install-local", "-l", "/path/to/package.pkg.tar.zst");

            config.AddCommand<RemoveCommand>("remove")
                .WithDescription("Remove one or more packages")
                .WithExample("remove", "firefox")
                .WithExample("remove", "firefox", "vlc")
                .WithExample("remove", "firefox", "--no-confirm");

            config.AddCommand<UpdateCommand>("update")
                .WithDescription("Update one or more packages")
                .WithExample("update", "firefox")
                .WithExample("update", "firefox", "vlc")
                .WithExample("update", "firefox", "--no-confirm");

            config.AddCommand<UpgradeCommand>("upgrade")
                .WithDescription("Perform a full system upgrade")
                .WithExample("upgrade")
                .WithExample("upgrade", "--no-confirm");

            config.AddCommand<DowngradePackageCommand>("downgrade")
                .WithDescription("Downgrade a package")
                .WithExample("downgrade", "firefox")
                .WithExample("downgrade", "firefox", "--oldest")
                .WithExample("downgrade", "firefox", "--latest");

            config.AddCommand<ArchNews>("news")
                .WithDescription("Shows Arch news you haven't seen before")
                .WithExample("news", "--all");

            config.AddBranch("keyring", keyring =>
            {
                keyring.SetDescription("Manage pacman keyring");

                keyring.AddCommand<KeyringInitCommand>("init")
                    .WithDescription("Initialize the pacman keyring")
                    .WithExample("keyring", "init");

                keyring.AddCommand<KeyringPopulateCommand>("populate")
                    .WithDescription("Reload keys from keyrings in /usr/share/pacman/keyrings")
                    .WithExample("keyring", "populate")
                    .WithExample("keyring", "populate", "archlinux");

                keyring.AddCommand<KeyringRecvCommand>("recv")
                    .WithDescription("Receive keys from a keyserver")
                    .WithExample("keyring", "recv", "0x12345678")
                    .WithExample("keyring", "recv", "0x12345678", "--keyserver", "keyserver.ubuntu.com");

                keyring.AddCommand<KeyringLsignCommand>("lsign")
                    .WithDescription("Locally sign the specified key(s)")
                    .WithExample("keyring", "lsign", "0x12345678");

                keyring.AddCommand<KeyringListCommand>("list")
                    .WithDescription("List all keys in the keyring")
                    .WithExample("keyring", "list");

                keyring.AddCommand<KeyringRefreshCommand>("refresh")
                    .WithDescription("Refresh keys from the keyserver")
                    .WithExample("keyring", "refresh");
            });

            config.AddBranch("aur", aur =>
            {
                aur.SetDescription("Manage AUR packages");

                aur.AddCommand<AurSearchCommand>("search")
                    .WithDescription("Search for AUR packages")
                    .WithExample("aur", "search", "yay");

                aur.AddCommand<AurListInstalledCommand>("list-installed")
                    .WithDescription("List installed AUR packages")
                    .WithExample("aur", "list-installed")
                    .WithExample("aur", "list-installed", "--sort", "name")
                    .WithExample("aur", "list-installed", "--sort", "popularity")
                    .WithExample("aur", "list-installed", "--sort", "popularity", "--order", "desc")
                    .WithExample("aur", "list-installed", "--filter", "yay");

                aur.AddCommand<AurListUpdatesCommand>("list-updates")
                    .WithDescription("List AUR packages that need updates")
                    .WithExample("aur", "list-updates")
                    .WithExample("aur", "list-updates", "--sort", "name")
                    .WithExample("aur", "list-updates", "--sort", "size")
                    .WithExample("aur", "list-updates", "--sort", "size", "--order", "desc")
                    .WithExample("aur", "list-updates", "--filter", "paru");

                aur.AddCommand<AurInstallCommand>("install")
                    .WithDescription("Install AUR packages")
                    .WithExample("aur", "install", "yay")
                    .WithExample("aur", "install", "yay", "paru")
                    .WithExample("aur", "install", "yay", "--no-confirm")
                    .WithExample("aur", "install", "yay", "--build-deps")
                    .WithExample("aur", "install", "yay", "-o")
                    .WithExample("aur", "install", "yay", "--make-deps")
                    .WithExample("aur", "install", "yay", "-m")
                    .WithExample("aur", "install", "yay", "--build-deps", "--make-deps")
                    .WithExample("aur", "install", "yay", "-o", "-m");

                aur.AddCommand<AurInstallVersionCommand>("install-version")
                    .WithDescription("Install a specific version of an AUR package by commit hash")
                    .WithExample("aur", "install-version", "yay", "abc1234");

                aur.AddCommand<AurUpdateCommand>("update")
                    .WithDescription("Update specific AUR packages")
                    .WithExample("aur", "update", "yay")
                    .WithExample("aur", "update", "yay", "paru")
                    .WithExample("aur", "update", "yay", "--no-confirm");

                aur.AddCommand<AurUpgradeCommand>("upgrade")
                    .WithDescription("Upgrade all AUR packages")
                    .WithExample("aur", "upgrade")
                    .WithExample("aur", "upgrade", "--no-confirm");

                aur.AddCommand<AurRemoveCommand>("remove")
                    .WithDescription("Remove AUR packages")
                    .WithExample("aur", "remove", "yay")
                    .WithExample("aur", "remove", "yay", "paru")
                    .WithExample("aur", "remove", "yay", "--no-confirm");

                aur.AddCommand<AurSearchPackageBuild>("get-package-build").WithDescription("Get package build")
                    .WithExample("aur", "get-package-build", "yay", "paru");
            });

            config.AddBranch("flatpak", flatpak =>
            {
                flatpak.SetDescription("Manage flatpak");

                flatpak.AddCommand<FlatpakInstallCommand>("install")
                    .WithDescription("Install flatpak app")
                    .WithExample("flatpak", "install", "com.spotify.Client");

                flatpak.AddCommand<FlatpakUpdateCommand>("update")
                    .WithDescription("Update flatpak app")
                    .WithExample("flatpak", "update", "com.spotify.Client");

                flatpak.AddCommand<FlatpakListCommand>("list")
                    .WithDescription("List installed flatpak apps")
                    .WithExample("flatpak", "list");

                flatpak.AddCommand<FlatpakListUpdatesCommand>("list-updates")
                    .WithDescription("List installed flatpak apps")
                    .WithExample("flatpak", "list-updates");

                flatpak.AddCommand<FlatpakRunningCommand>("running")
                    .WithDescription("List running flatpak apps")
                    .WithExample("flatpak", "running");

                flatpak.AddCommand<FlatpakRemoveCommand>("uninstall")
                    .WithDescription("Remove flatpak app")
                    .WithExample("flatpak", "uninstall", "com.spotify.Client");

                flatpak.AddCommand<FlatpakRunCommand>("run")
                    .WithDescription("Run flatpak app")
                    .WithExample("flatpak", "run", "com.spotify.Client");

                flatpak.AddCommand<FlatpakKillCommand>("kill")
                    .WithDescription("Kill running flatpak app")
                    .WithExample("flatpak", "kill", "com.spotify.Client");

                flatpak.AddCommand<FlathubSearchCommand>("search")
                    .WithDescription("Search flatpak")
                    .WithExample("flatpak", "search", "spotify")
                    .WithExample("flatpak", "search", "spotify", "--limit", "10")
                    .WithExample("flatpak", "search", "spotify", "--page", "2");

                flatpak.AddCommand<FlatpakSyncRemoteAppStream>("sync-remote-appstream")
                    .WithDescription("Sync remote appstream")
                    .WithExample("flatpak", "sync-remote-appstream");

                flatpak.AddCommand<FlathubGetRemote>("get-remote-appstream")
                    .WithDescription("Returns remote appstream json")
                    .WithExample("flatpak", "sync-get-remote-appstream");

                flatpak.AddCommand<FlatpakUpgrade>("upgrade")
                    .WithDescription("Upgrade all flatpak apps")
                    .WithExample("flatpak", "upgrade");

                flatpak.AddCommand<FlatpakListRemotes>("list-remotes")
                    .WithDescription("Returns all remotes currently added");

                flatpak.AddCommand<FlatpakAddRemote>("add-remotes")
                    .WithDescription("Adds a flatpak remote");

                flatpak.AddCommand<FlatpakRemoveRemote>("remove-remotes").WithDescription("Removes a flatpak remote");
                

                flatpak.AddCommand<GetAppRemoteInfo>("app-remote-info").WithDescription("Get app remote info");
            });

            config.AddBranch("utility", utility =>
            {
                utility.SetDescription("shelly utils");

                utility.AddCommand<Export>("export").WithDescription("export sync file").WithExample("utility export")
                    .WithExample("utility export -o ~/Downloads/");

                utility.AddCommand<CheckPackageUpdatesNonRootCommand>("updates")
                    .WithDescription("checks for updates as non-root user")
                    .WithExample("utility", "updates")
                    .WithExample("utility", "updates", "-a")
                    .WithExample("utility", "updates", "--aur")
                    .WithExample("utility", "updates", "-l")
                    .WithExample("utility", "updates", "--flatpak");
            });
        });

        return app.Run(args);
    }
}