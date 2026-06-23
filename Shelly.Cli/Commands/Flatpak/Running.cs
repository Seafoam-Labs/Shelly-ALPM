using System.CommandLine;
using System.Text.Json;
using PackageManager.Flatpak;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Commands.Flatpak;

public class Running : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("running", "List running flatpak apps");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Running();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override ValueTask ExecuteAsync(IShellyConsole console)
    {
        var result = new FlatpakManager().GetRunningInstances().OrderBy(pkg => pkg.Pid).ToList();

        if (UiMode)
        {
            JsonPackFrame.WriteToStdout(result);
            return ValueTask.CompletedTask;
        }

        if (JsonOutput)
        {
            console.WriteLine(JsonSerializer.Serialize(result, ShellyCliJsonContext.Default.ListFlatpakInstanceDto));
            return ValueTask.CompletedTask;
        }

        console.WriteLine(AnsiUtilities.Colorize("Currently running flatpak instances on machine...", ConsoleColor.Yellow));

        if (result.Count > 0)
        {
            console.WriteLine(BasicTable.Execute(
                ["Id", "Pid"], result,
                pkg => pkg.AppId,
                pkg => pkg.Pid.ToString()));
            return ValueTask.CompletedTask;
        }

        console.WriteLine(AnsiUtilities.Colorize("No instances running", ConsoleColor.Green));
        return ValueTask.CompletedTask;
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;
}
