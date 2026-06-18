using System.CommandLine;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Config;

public class ConfigSet : GlobalSettingsCommand
{
    private string Key { get; set; } = string.Empty;

    private string Value { get; set; } = string.Empty;

    public static Command Create()
    {
        var key = new Argument<string>("key") { Description = "The configuration key to set" };
        var value = new Argument<string>("value") { Description = "The value to set" };

        var command = new Command("set", "Set a configuration value") { key, value };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new ConfigSet
            {
                Key = parseResult.GetValue(key) ?? string.Empty,
                Value = parseResult.GetValue(value) ?? string.Empty
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

        if (ConfigManager.UpdateConfig(Key, Value))
            console.WriteLine(Colorize($"Set {Key} to {Value}", ConsoleColor.Green));
        else
            console.WriteLine(Colorize($"Failed to set configuration key: {Key}", ConsoleColor.Red));
    }

    public override ValueTask ExecuteUiMode()
    {
        if (ConfigManager.UpdateConfig(Key, Value))
            UiFrames.Info($"Set {Key} to {Value}");
        else
            UiFrames.Error($"Failed to set configuration key: {Key}");

        return ValueTask.CompletedTask;
    }
}
