using System.CommandLine;
using PackageManager.Flatpak;
using PackageManager.Flatpak.Enums;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class Install : GlobalSettingsCommand
{
    /// <summary>
    /// Resolved no-confirm for flatpakinstall actions: per-action flag OR global flag.
    /// </summary>
    private bool EffectiveNoConfirm => NoConfirmFlatpakInstall ?? false || NoConfirm;

    private string Package { get; set; } = string.Empty;
    private bool IsUser { get; set; }
    private string? Remote { get; set; }
    private string? Branch { get; set; }
    private bool IsRuntime { get; set; }

    public static Command Create()
    {
        var package = new Argument<string>("package")
            { Description = "Flatpak application ID (e.g., com.spotify.Client)" };
        var user = new Option<bool>("--user") { Description = "Install to user scope instead of system scope" };
        var remote = new Option<string?>("--remote", "-r")
            { Description = "Remote to install from (e.g., flathub, flathub-beta)" };
        var branch = new Option<string?>("--branch", "-b")
            { Description = "Branch to install (e.g., stable, beta). Defaults to stable" };
        var runtime = new Option<bool>("--runtime") { Description = "Install as a runtime instead of an application" };

        var command = new Command("install", "Install flatpak app")
        {
            package, user, remote, branch, runtime
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Install
            {
                Package = parseResult.GetValue(package) ?? string.Empty,
                IsUser = parseResult.GetValue(user),
                Remote = parseResult.GetValue(remote),
                Branch = parseResult.GetValue(branch),
                IsRuntime = parseResult.GetValue(runtime)
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(ShellyConsoleFactory.Create());
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

        var manager = new FlatpakManager();

        var packageToInstall = Package;
        var remoteToUse = Remote;

        if (!Package.Contains('.') && string.IsNullOrEmpty(Remote))
        {
            console.WriteLine(Colorize($"Searching for packages matching '{Package}'...", ConsoleColor.Cyan));
            var matches = manager.SearchRemoteRefs(Package);

            switch (matches.Count)
            {
                case 0:
                    console.WriteLine(Colorize($"No matches found for '{Package}'. Proceeding with literal name.",
                        ConsoleColor.Yellow));
                    break;
                case 1:
                {
                    var match = matches[0];
                    console.WriteLine(Colorize($"Found match: {match.Name} ({match.Id}) from {match.Remote}",
                        ConsoleColor.Green));
                    packageToInstall = match.Id;
                    remoteToUse = match.Remote;
                    break;
                }
                default:
                {
                    console.WriteLine(Colorize($"Found multiple matches for '{Package}':", ConsoleColor.Yellow));
                    var options = matches.Select(m => $"{m.Name} ({m.Id}) [{m.Remote}] [{m.InstallLevel.ToString()}]")
                        .ToList();
                    var index = BasicSelection.Execute("Select a package to install:", options);

                    if (index < 0 || index >= matches.Count)
                    {
                        console.WriteLine(Colorize("Invalid selection. Aborting.", ConsoleColor.Red));
                        return;
                    }

                    var selected = matches[index];
                    packageToInstall = selected.Id;
                    remoteToUse = selected.Remote;
                    break;
                }
            }
        }

        console.WriteLine(Colorize("Installing flatpak app...", ConsoleColor.Yellow));

        await FlatpakSinglePaneOutput.Output(console, manager,
            x => x.InstallApp(packageToInstall, IsUser ? InstallLevel.User : InstallLevel.System, Branch ?? "stable",
                remoteToUse, IsRuntime), EffectiveNoConfirm);
    }

    public override async ValueTask ExecuteUiMode()
    {
        UiFrames.TxStart("Installing flatpak app...");
        var manager = new FlatpakManager();
        await UiModeOutput.Run(manager,
            m => manager.InstallApp(Package, IsUser ? InstallLevel.User : InstallLevel.System, Branch ?? "stable",
                Remote, IsRuntime));
        UiFrames.TxDone("Flatpak install complete.");
    }
}