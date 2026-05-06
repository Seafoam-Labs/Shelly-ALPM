using Shelly_CLI.Enums;
using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using PackageManager.Utilities;
using Shelly.Utilities;

namespace Shelly_CLI.Configuration;

public static class ConfigManager
{
    public static string GetConfigPath() => XdgPaths.ShellyConfig("config.json");

    public static ShellyConfig ReadConfig()
    {
        var configPath = GetConfigPath();

        if (!File.Exists(configPath))
        {
            return CreateConfig();
        }

        var json = File.ReadAllText(configPath);
        return JsonSerializer.Deserialize(json, ShellyCLIJsonContext.Default.ShellyConfig) ??
               new ShellyConfig();
    }

    public static ShellyConfig CreateConfig()
    {
        var configPath = GetConfigPath();

        if (!File.Exists(configPath))
        {
            var configDir = Path.GetDirectoryName(configPath);
            if (!string.IsNullOrEmpty(configDir))
            {
                try
                {
                    Directory.CreateDirectory(configDir);
                }
                catch (UnauthorizedAccessException ex)
                {
                    Console.Error.WriteLine($"Cannot create config dir '{configDir}': {ex.Message}");
                    return new ShellyConfig();
                }
                catch (IOException ex)
                {
                    Console.Error.WriteLine($"Cannot create config dir '{configDir}': {ex.Message}");
                    return new ShellyConfig();
                }
            }

            var defaultConfig = new ShellyConfig();
            try
            {
                WriteConfig(defaultConfig, configPath);
            }
            catch (UnauthorizedAccessException ex)
            {
                Console.Error.WriteLine($"Cannot write config '{configPath}': {ex.Message}");
                return defaultConfig;
            }
            catch (IOException ex)
            {
                Console.Error.WriteLine($"Cannot write config '{configPath}': {ex.Message}");
                return defaultConfig;
            }

            if (IsRunningAsRoot() && !string.IsNullOrEmpty(configDir))
            {
                FixOwnership(configDir);
            }
        }

        var json = File.ReadAllText(configPath);
        return JsonSerializer.Deserialize(json, ShellyCLIJsonContext.Default.ShellyConfig) ??
               new ShellyConfig();
    }

    public static void SaveConfig(ShellyConfig config)
    {
        var configPath = GetConfigPath();
        var configDir = Path.GetDirectoryName(configPath);
        if (!string.IsNullOrEmpty(configDir))
        {
            Directory.CreateDirectory(configDir);
        }

        WriteConfig(config, configPath);

        if (IsRunningAsRoot() && !string.IsNullOrEmpty(configDir))
        {
            FixOwnership(configDir);
        }
    }

    public static bool UpdateConfig(string key, string value)
    {
        var config = ReadConfig();
        var property = typeof(ShellyConfig).GetProperty(key,
            BindingFlags.Public | BindingFlags.Instance | BindingFlags.IgnoreCase);

        if (property == null)
        {
            return false;
        }

        var targetType = Nullable.GetUnderlyingType(property.PropertyType) ?? property.PropertyType;

        object? convertedValue;
        try
        {
            if (targetType == typeof(bool))
            {
                convertedValue = bool.Parse(value);
            }
            else if (targetType == typeof(int))
            {
                convertedValue = int.Parse(value);
            }
            else if (targetType == typeof(double))
            {
                convertedValue = double.Parse(value);
            }
            else if (targetType == typeof(TimeOnly))
            {
                if (string.IsNullOrEmpty(value) || value.Equals("null", StringComparison.OrdinalIgnoreCase))
                {
                    convertedValue = null;
                }
                else
                {
                    convertedValue = TimeOnly.Parse(value);
                }
            }
            else if (targetType == typeof(List<DayOfWeek>))
            {
                if (string.IsNullOrEmpty(value) || value == "[]")
                {
                    convertedValue = new List<DayOfWeek>();
                }
                else
                {
                    convertedValue = value.Split(',',
                            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                        .Select(d => Enum.Parse<DayOfWeek>(d, true))
                        .ToList();
                }
            }
            else
            {
                if (property.Name == nameof(ShellyConfig.ProgressBarStyle))
                {
                    if (!Enum.TryParse<ProgressBarStyleKind>(value, true, out var parsed))
                    {
                        return false;
                    }
                    convertedValue = parsed.ToString();
                }
                else if (property.Name == nameof(ShellyConfig.FileSizeDisplay))
                {
                    if (!Enum.TryParse<SizeDisplay>(value, true, out var parsed))
                    {
                        return false;
                    }
                    convertedValue = parsed.ToString();
                }
                else if (property.Name == nameof(ShellyConfig.DefaultExecution))
                {
                    if (!Enum.TryParse<DefaultCommand>(value, true, out var parsed))
                    {
                        return false;
                    }

                    convertedValue = parsed.ToString();
                }
                else if (property.Name == nameof(ShellyConfig.DefaultPageDropDown))
                {
                    if (!Enum.TryParse<ShellyTabs>(value, true, out var parsed))
                    {
                        return false;
                    }

                    convertedValue = parsed;
                }
                else
                {
                    convertedValue = value;
                }
            }
        }
        catch
        {
            return false;
        }

        property.SetValue(config, convertedValue);
        SaveConfig(config);
        return true;
    }

    public static string? GetConfigValue(string key)
    {
        var config = ReadConfig();
        var property = typeof(ShellyConfig).GetProperty(key,
            BindingFlags.Public | BindingFlags.Instance | BindingFlags.IgnoreCase);

        if (property == null)
        {
            return null;
        }

        var value = property.GetValue(config);
        if (value is List<DayOfWeek> days)
        {
            return string.Join(",", days);
        }

        return value?.ToString();
    }

    public static Dictionary<string, string?> GetAllConfigValues()
    {
        var config = ReadConfig();
        var result = new Dictionary<string, string?>();

        foreach (var property in typeof(ShellyConfig).GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            var value = property.GetValue(config);
            if (value is List<DayOfWeek> days)
            {
                result[property.Name] = string.Join(",", days);
            }
            else
            {
                result[property.Name] = value?.ToString();
            }
        }

        return result;
    }

    public static void MigrateFromUiConfig()
    {
        var oldConfigFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shelly");
        var oldConfigPath = Path.Combine(oldConfigFolder, "settings.json");

        if (!File.Exists(oldConfigPath))
        {
            return;
        }

        try
        {
            var oldJson = File.ReadAllText(oldConfigPath);
            using var doc = JsonDocument.Parse(oldJson);
            var root = doc.RootElement;

            var config = ReadConfig();

            if (root.TryGetProperty("AccentColor", out var accentColor) &&
                accentColor.ValueKind == JsonValueKind.String)
            {
                config.AccentColor = accentColor.GetString();
            }

            if (root.TryGetProperty("Culture", out var culture) && culture.ValueKind == JsonValueKind.String)
            {
                config.Culture = culture.GetString();
            }

            if (root.TryGetProperty("DarkMode", out var darkMode))
            {
                config.DarkMode = darkMode.GetBoolean();
            }

            if (root.TryGetProperty("AurEnabled", out var aurEnabled))
            {
                config.AurEnabled = aurEnabled.GetBoolean();
            }

            if (root.TryGetProperty("ShellySearchEnabled", out var shellySearchEnabled))
            {
                config.ShellySearchEnabled = shellySearchEnabled.GetBoolean();
            }
            else if (root.TryGetProperty("MetaSearchEnabled", out var metaSearchEnabled))
            {
                // Backward compatibility: previously named MetaSearchEnabled
                config.ShellySearchEnabled = metaSearchEnabled.GetBoolean();
            }

            if (root.TryGetProperty("AurWarningConfirmed", out var aurWarning))
            {
                config.AurWarningConfirmed = aurWarning.GetBoolean();
            }

            if (root.TryGetProperty("FlatPackEnabled", out var flatpack))
            {
                config.FlatPackEnabled = flatpack.GetBoolean();
            }

            if (root.TryGetProperty("ConsoleEnabled", out var console))
            {
                config.ConsoleEnabled = console.GetBoolean();
            }

            if (root.TryGetProperty("WindowWidth", out var width))
            {
                config.WindowWidth = width.GetDouble();
            }

            if (root.TryGetProperty("WindowHeight", out var height))
            {
                config.WindowHeight = height.GetDouble();
            }

            if (root.TryGetProperty("DefaultView", out var defaultView))
            {
                config.DefaultView = defaultView.ToString();
            }

            if (root.TryGetProperty("UseKdeTheme", out var kde))
            {
                config.UseKdeTheme = kde.GetBoolean();
            }

            if (root.TryGetProperty("UseOldMenu", out var oldMenu))
            {
                config.UseOldMenu = oldMenu.GetBoolean();
            }
            else if (root.TryGetProperty("UseHorizontalMenu", out var horizontal))
            {
                config.UseOldMenu = horizontal.GetBoolean();
            }

            if (root.TryGetProperty("TrayEnabled", out var tray))
            {
                config.TrayEnabled = tray.GetBoolean();
            }

            if (root.TryGetProperty("TrayCheckIntervalHours", out var interval))
            {
                config.TrayCheckIntervalHours = interval.GetInt32();
            }

            if (root.TryGetProperty("NoConfirm", out var noConfirm))
            {
                config.NoConfirm = noConfirm.GetBoolean();
            }

            if (root.TryGetProperty("NewInstall", out var newInstall))
            {
                config.NewInstall = newInstall.GetBoolean();
            }

            if (root.TryGetProperty("NewInstallInitSettings", out var initSettings))
            {
                config.NewInstallInitSettings = initSettings.GetBoolean();
            }

            if (root.TryGetProperty("CurrentVersion", out var version) && version.ValueKind == JsonValueKind.String)
            {
                config.CurrentVersion = version.GetString() ?? "0.0.0";
            }

            if (root.TryGetProperty("UseWeeklySchedule", out var weekly))
            {
                config.UseWeeklySchedule = weekly.GetBoolean();
            }

            if (root.TryGetProperty("WebViewEnabled", out var webView))
            {
                config.WebViewEnabled = webView.GetBoolean();
            }

            if (root.TryGetProperty("DaysOfWeek", out var days) && days.ValueKind == JsonValueKind.Array)
            {
                config.DaysOfWeek = [];
                foreach (var day in days.EnumerateArray())
                {
                    switch (day.ValueKind)
                    {
                        case JsonValueKind.String when
                            Enum.TryParse<DayOfWeek>(day.GetString(), true, out var d):
                            config.DaysOfWeek.Add(d);
                            break;
                        case JsonValueKind.Number:
                            config.DaysOfWeek.Add((DayOfWeek)day.GetInt32());
                            break;
                        default:
                            throw new ArgumentOutOfRangeException();
                    }
                }
            }

            if (root.TryGetProperty("Time", out var time) && time.ValueKind == JsonValueKind.String)
            {
                if (TimeOnly.TryParse(time.GetString(), out var t))
                    config.Time = t;
            }

            if (root.TryGetProperty("DefaultPageDropDown", out var defaultPage))
            {
                config.DefaultPageDropDown = (ShellyTabs)defaultPage.GetInt32();
            }
            
            if (root.TryGetProperty("TrayUpdatesIconPath", out var trayUpdatesIconPath))
            {
                config.TrayUpdatesIconPath =  trayUpdatesIconPath.GetString();
            }
            
            if (root.TryGetProperty("TrayIconPath", out var trayIconPath))
            {
                config.TrayIconPath =  trayIconPath.GetString();
            }
            
            SaveConfig(config);

            // Rename old config to indicate migration
            File.Move(oldConfigPath, oldConfigPath + ".migrated", true);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Warning: Failed to migrate UI settings: {ex.Message}");
        }
    }

    public static bool IsOwnedByRoot(string path)
    {
        if (!File.Exists(path)) return false;

        try
        {
            var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "stat",
                    Arguments = $"-c %u \"{path}\"",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };
            process.Start();
            var output = process.StandardOutput.ReadToEnd().Trim();
            process.WaitForExit(3000);
            return output == "0";
        }
        catch
        {
            return false;
        }
    }

    public static void FixConfigOwnershipIfNeeded()
    {
        var configPath = GetConfigPath();
        var configDir = Path.GetDirectoryName(configPath);

        if (string.IsNullOrEmpty(configDir)) return;

        if (IsRunningAsRoot() && (IsOwnedByRoot(configPath) || IsOwnedByRoot(configDir)))
        {
            FixOwnership(configDir);
        }
    }

    private static bool IsRunningAsRoot()
        => Environment.GetEnvironmentVariable("USER") == "root";

    private static string? GetRealUser()
        => Environment.GetEnvironmentVariable("SUDO_USER");

    private static void FixOwnership(string path)
    {
        var user = GetRealUser();
        if (string.IsNullOrEmpty(user)) return;

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "chown",
                Arguments = $"-R {user}:{user} \"{path}\"",
                UseShellExecute = false,
                CreateNoWindow = true
            }
        };
        process.Start();
        process.WaitForExit(5000);
    }

    private static void WriteConfig(ShellyConfig config, string configPath)
    {
        var options = new JsonSerializerOptions { WriteIndented = true };
        var json = JsonSerializer.Serialize(config, typeof(ShellyConfig), new ShellyCLIJsonContext(options));
        File.WriteAllText(configPath, json);
    }
}