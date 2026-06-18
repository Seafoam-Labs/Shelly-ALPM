using System.CommandLine;
using System.Text.Json;
using PackageManager.Flatpak;

namespace Shelly.Cli.Commands.Flatpak;

public class GetRemoteAppStream : GlobalSettingsCommand
{
    private string AppStreamName { get; set; } = string.Empty;

    public static Command Create()
    {
        var query = new Argument<string>("query") { Description = "Gets appstream data in json (use all to retrieve all appstreams)" };

        var command = new Command("get-remote-appstream", "Returns remote appstream json")
        {
            query
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new GetRemoteAppStream
            {
                AppStreamName = parseResult.GetValue(query) ?? string.Empty
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
        var result = AppStreamName == "all"
            ? manager.GetAvailableAppsFromAppstreamJson("all", getAll: true)
            : manager.GetAvailableAppsFromAppstreamJson(AppStreamName);

        if (UiMode)
        {
            JsonPackFrame.WriteToStdout(result);
            return ValueTask.CompletedTask;
        }

        console.WriteLine(JsonSerializer.Serialize(result, ShellyCliJsonContext.Default.ListAppstreamApp));
        return ValueTask.CompletedTask;
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;
}
