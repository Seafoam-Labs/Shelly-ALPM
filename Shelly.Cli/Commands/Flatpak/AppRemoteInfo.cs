using System.CommandLine;
using System.Text.Json;
using PackageManager.Flatpak;

namespace Shelly.Cli.Commands.Flatpak;

public class AppRemoteInfo : GlobalSettingsCommand
{
    private string Remote { get; set; } = string.Empty;
    private string Name { get; set; } = string.Empty;
    private string Branch { get; set; } = string.Empty;

    public static Command Create()
    {
        var remote = new Argument<string>("remote") { Description = "Flatpak remote name (e.g., flathub)" };
        var id = new Argument<string>("id") { Description = "Flatpak application ID" };
        var branch = new Argument<string>("branch") { Description = "Branch to query (e.g., stable)" };

        var command = new Command("app-remote-info", "Get app remote info")
        {
            remote, id, branch
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new AppRemoteInfo
            {
                Remote = parseResult.GetValue(remote) ?? string.Empty,
                Name = parseResult.GetValue(id) ?? string.Empty,
                Branch = parseResult.GetValue(branch) ?? string.Empty
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
        var result = manager.GetRemoteSize(Remote, Name, "", Branch);

        if (UiMode)
        {
            JsonPackFrame.WriteToStdout(result);
            return ValueTask.CompletedTask;
        }

        if (JsonOutput)
        {
            console.WriteLine(JsonSerializer.Serialize(result, ShellyCliJsonContext.Default.FlatpakRemoteRefInfo));
            return ValueTask.CompletedTask;
        }

        console.Write(
            $"Download Size: {FormatSize(result.DownloadSize)} Install Size: {FormatSize(result.InstalledSize)} Permissions: {string.Join(", ", result.Permissions)} ");
        return ValueTask.CompletedTask;
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;

    private static string FormatSize(ulong bytes)
    {
        string[] suffixes = ["B", "KB", "MB", "GB", "TB"];
        var i = 0;
        double dblSByte = bytes;
        while (i < suffixes.Length && bytes >= 1024)
        {
            dblSByte = bytes / 1024.0;
            i++;
            bytes /= 1024;
        }

        return $"{dblSByte:0.##} {suffixes[i]}";
    }
}
