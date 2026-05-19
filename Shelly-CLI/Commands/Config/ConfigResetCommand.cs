using Shelly_CLI.Configuration;
using Shelly.Utilities;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Config;

public class ConfigResetCommand : Command
{
    public override int Execute(CommandContext context)
    {
        var defaultConfig = new ShellyConfig();
        ConfigManager.SaveConfig(defaultConfig);
        AnsiConsole.MarkupLine("[green]Configuration reset to defaults[/]");
        return 0;
    }
}
