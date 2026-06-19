using System.CommandLine;
using PackageManager.Flatpak;
using Shelly.Cli.Outputs;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class Install : GlobalSettingsCommand
{
    private string Package { get; set; } = string.Empty;
    private bool IsUser { get; set; }
    private string? Remote { get; set; }
    private string? Branch { get; set; }
    private bool IsRuntime { get; set; }

    public static Command Create()
    {
        var package = new Argument<string>("package") { Description = "Flatpak application ID (e.g., com.spotify.Client)" };
        var user = new Option<bool>("--user") { Description = "Install to user scope instead of system scope" };
        var remote = new Option<string?>("--remote", "-r") { Description = "Remote to install from (e.g., flathub, flathub-beta)" };
        var branch = new Option<string?>("--branch", "-b") { Description = "Branch to install (e.g., stable, beta). Defaults to stable" };
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

        console.WriteLine(Colorize("Installing flatpak app...", ConsoleColor.Yellow));
        var manager = new FlatpakManager();
        await FlatpakSinglePaneOutput.Output(console, manager,
            x => x.InstallApp(Package, Remote, IsUser, Branch ?? "stable", IsRuntime), NoConfirm);
    }

    public async override ValueTask ExecuteUiMode()
    {
        UiFrames.TxStart("Installing flatpak app...");
        var manager = new FlatpakManager();
        await UiModeOutput.Run(manager, m =>  manager.InstallApp(Package, Remote, IsUser, Branch ?? "stable", IsRuntime));
        UiFrames.TxDone("Flatpak install complete.");
      
    }
}
