using System.CommandLine;
using PackageManager.Flatpak;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class AddRemote : GlobalSettingsCommand
{
    private string RemoteName { get; set; } = string.Empty;
    private string RemoteUrl { get; set; } = string.Empty;
    private bool SystemWide { get; set; }
    private bool GpgVerify { get; set; }

    public static Command Create()
    {
        var remoteName = new Argument<string>("remote") { Description = "Flatpak remote name ID (e.g., flathub)" };
        var remoteUrl = new Option<string>("--remote-url", "-u") { Description = "Flatpak remote URL", Required = true };
        var system = new Option<bool>("--system", "-s") { Description = "Add the remote system-wide", DefaultValueFactory = _ => true };
        var gpgVerify = new Option<bool>("--gpg-verify", "-g") { Description = "Enable GPG verification for the remote", DefaultValueFactory = _ => true };

        var command = new Command("add-remotes", "Adds a flatpak remote")
        {
            remoteName, remoteUrl, system, gpgVerify
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new AddRemote
            {
                RemoteName = parseResult.GetValue(remoteName) ?? string.Empty,
                RemoteUrl = parseResult.GetValue(remoteUrl) ?? string.Empty,
                SystemWide = parseResult.GetValue(system),
                GpgVerify = parseResult.GetValue(gpgVerify)
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override ValueTask ExecuteAsync(IShellyConsole console)
    {
        var manager = new FlatpakManager();
        console.WriteLine(Colorize($"Adding remote {RemoteName}", ConsoleColor.Blue));
        var result = manager.AddRemote(RemoteName, RemoteUrl, SystemWide, GpgVerify);
        console.WriteLine(result);
        return ValueTask.CompletedTask;
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;
}
