using System.CommandLine;
using System.Text.Json;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Config;

public class ConfigList : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("list", "List all configuration values");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new ConfigList();
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

        var values = ConfigManager.GetAllConfigValues();

        if (JsonOutput)
        {
            console.WriteLine(JsonSerializer.Serialize(values,
                ShellyCliJsonContext.Default.DictionaryStringString));
            return;
        }

        var width = values.Count == 0 ? 0 : values.Keys.Max(k => k.Length);
        foreach (var (key, value) in values)
            console.WriteLine($"{Colorize(key.PadRight(width), ConsoleColor.Cyan)}  {value ?? "(null)"}");
    }

    public override ValueTask ExecuteUiMode()
    {
        UiFrames.Frame(ConfigManager.GetAllConfigValues());
        return ValueTask.CompletedTask;
    }
}
