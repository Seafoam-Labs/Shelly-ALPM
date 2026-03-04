using System.Text.Json;

namespace Shelly_CLI.Configuration;

public static class ConfigManager
{
    public static ShellyConfig ReadConfig()
    {
        var username = Environment.GetEnvironmentVariable("SUDO_USER");
        var configPath = Path.Combine("/home", username, ".config", "shelly", "config.json");
        Console.WriteLine(configPath);
        if (!File.Exists(configPath))
        {
            CreateConfig();
        }

        var json = File.ReadAllText(configPath);

        return JsonSerializer.Deserialize<ShellyConfig>(json, ShellyCLIJsonContext.Default.ShellyConfig) ??
               new ShellyConfig();
    }

    public static ShellyConfig CreateConfig()
    {
        string configPath;
        if (Environment.GetEnvironmentVariable("USER") == "root")
        {
            var username = Environment.GetEnvironmentVariable("SUDO_USER");
            configPath = Path.Combine("/home", username, ".config", "shelly", "config.json");
        }
        else
        {
            configPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "shelly", "config.json");
        }

        if (!File.Exists(configPath))
        {
            var configDir = Path.GetDirectoryName(configPath);
            if (!string.IsNullOrEmpty(configDir))
            {
                Directory.CreateDirectory(configDir);
            }

            var defaultConfig = new ShellyConfig();
            var options = new JsonSerializerOptions { WriteIndented = true };
            var json = JsonSerializer.Serialize(defaultConfig, typeof(ShellyConfig), new ShellyCLIJsonContext(options));
            File.WriteAllText(configPath, json);
        }

        return ReadConfig();
    }
}