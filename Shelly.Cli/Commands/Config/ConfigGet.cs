using System.CommandLine;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Config;

public class ConfigGet : GlobalSettingsCommand
{
    private string Key { get; set; } = string.Empty;

    public static Command Create()
    {
        var key = new Argument<string>("key") { Description = "The configuration key to get" };

        var command = new Command("get", "Get a configuration value") { key };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new ConfigGet
            {
                Key = parseResult.GetValue(key) ?? string.Empty
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

        var value = ConfigManager.GetConfigValue(Key);
        if (value is null)
        {
            console.WriteLine(Colorize($"Unknown configuration key: {Key}", ConsoleColor.Red));
            return;
        }

        console.WriteLine(value);
    }

    public override ValueTask ExecuteUiMode()
    {
        var value = ConfigManager.GetConfigValue(Key);
        if (value is null)
            UiFrames.Error($"Unknown configuration key: {Key}");
        else
            UiFrames.Frame(new Dictionary<string, string?> { [Key] = value });

        return ValueTask.CompletedTask;
    }
}
