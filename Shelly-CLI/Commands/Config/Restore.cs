using System.Text.Json;
using PackageManager.Utilities;
using Shelly_CLI.Configuration;
using Shelly.Utilities;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Config;

public class Restore : AsyncCommand
{
    public override async Task<int> ExecuteAsync(CommandContext context)
    {
        var configPath = XdgPaths.ShellyConfig("config.json");
        if (!File.Exists(configPath))
        {
            await CreateConfigFile(configPath);
            return 0;
        }

        File.Delete(configPath);
        await CreateConfigFile(configPath);
        return 0;
    }

    private static async Task CreateConfigFile(string configPath)
    {
        var file = File.CreateText(configPath);
        var json = JsonSerializer.Serialize<ShellyConfig>(new ShellyConfig(),
            ShellyCLIJsonContext.Default.ShellyConfig);
        await file.WriteAsync(json);
        file.Close();
    }
}