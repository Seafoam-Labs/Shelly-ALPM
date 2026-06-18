using System.CommandLine;
using Shelly.Utilities;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Config;

public class ConfigReset : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("reset", "Reset the configuration to defaults");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new ConfigReset();
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

        ConfigManager.SaveConfig(new ShellyConfig());
        console.WriteLine(Colorize("Configuration reset to defaults.", ConsoleColor.Green));
    }

    public override ValueTask ExecuteUiMode()
    {
        ConfigManager.SaveConfig(new ShellyConfig());
        UiFrames.Info("Configuration reset to defaults.");
        return ValueTask.CompletedTask;
    }
}
