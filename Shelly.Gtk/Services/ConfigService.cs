using System.Diagnostics;
using System.Text.Json;
using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Services;

public class ConfigService : IConfigService
{
    private static readonly string ConfigFolder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "shelly");

    private static readonly string ConfigPath = Path.Combine(ConfigFolder, "config.json");

    private ShellyConfig? _config = null;
    private readonly IDirtyService dirtyService;
    private bool _suppressInvalidate;

    public ConfigService(IDirtyService dirtyService)
    {
        this.dirtyService = dirtyService;
        dirtyService.Dirtied += (_, e) =>
        {
            if (_suppressInvalidate) return;
            if (e.Matches(DirtyScopes.Config)) _config = null;
        };
    }

    public event EventHandler<ShellyConfig>? ConfigSaved;

    public void SaveConfig(ShellyConfig config)
    {
        _config = config;

        CallCliConfigSet(nameof(config.AccentColor), config.AccentColor ?? "");
        CallCliConfigSet(nameof(config.Culture), config.Culture ?? "");
        CallCliConfigSet(nameof(config.DarkMode), config.DarkMode.ToString());
        CallCliConfigSet(nameof(config.AurEnabled), config.AurEnabled.ToString());
        CallCliConfigSet(nameof(config.ShellySearchEnabled), config.ShellySearchEnabled.ToString());
        CallCliConfigSet(nameof(config.AurWarningConfirmed), config.AurWarningConfirmed.ToString());
        CallCliConfigSet(nameof(config.FlatPackEnabled), config.FlatPackEnabled.ToString());
        CallCliConfigSet(nameof(config.AppImageEnabled), config.AppImageEnabled.ToString());
        CallCliConfigSet(nameof(config.ConsoleEnabled), config.ConsoleEnabled.ToString());
        CallCliConfigSet(nameof(config.WindowWidth), config.WindowWidth.ToString());
        CallCliConfigSet(nameof(config.WindowHeight), config.WindowHeight.ToString());
        CallCliConfigSet(nameof(config.DefaultView), config.DefaultView);
        CallCliConfigSet(nameof(config.UseKdeTheme), config.UseKdeTheme.ToString());
        CallCliConfigSet(nameof(config.UseOldMenu), config.UseOldMenu.ToString());
        CallCliConfigSet(nameof(config.TrayEnabled), config.TrayEnabled.ToString());
        CallCliConfigSet(nameof(config.TrayCheckIntervalHours), config.TrayCheckIntervalHours.ToString());
        CallCliConfigSet(nameof(config.NoConfirm), config.NoConfirm.ToString());
        CallCliConfigSet(nameof(config.NewInstall), config.NewInstall.ToString());
        CallCliConfigSet(nameof(config.CurrentVersion), config.CurrentVersion);
        CallCliConfigSet(nameof(config.UseWeeklySchedule), config.UseWeeklySchedule.ToString());
        CallCliConfigSet(nameof(config.DaysOfWeek), string.Join(",", config.DaysOfWeek));
        CallCliConfigSet(nameof(config.Time), config.Time?.ToString() ?? "");
        CallCliConfigSet(nameof(config.WebViewEnabled), config.WebViewEnabled.ToString());
        CallCliConfigSet(nameof(config.ShellyIconsEnabled), config.ShellyIconsEnabled.ToString());
        CallCliConfigSet(nameof(config.NewInstallInitSettings), config.NewInstallInitSettings.ToString());
        CallCliConfigSet(nameof(config.FileSizeDisplay), config.FileSizeDisplay);
        CallCliConfigSet(nameof(config.DefaultExecution), config.DefaultExecution);
        CallCliConfigSet(nameof(config.ParallelDownloadCount), config.ParallelDownloadCount.ToString());
        CallCliConfigSet(nameof(config.UseSymbolicTray), config.UseSymbolicTray.ToString());
        CallCliConfigSet(nameof(config.TrayIconPath), config.TrayIconPath ?? "");
        CallCliConfigSet(nameof(config.TrayUpdatesIconPath), config.TrayUpdatesIconPath ?? "");
        CallCliConfigSet(nameof(config.DefaultPageDropDown), config.DefaultPageDropDown.ToString());

        ConfigSaved?.Invoke(this, config);
        _suppressInvalidate = true;
        try { dirtyService.MarkDirty(DirtyScopes.Config); }
        finally { _suppressInvalidate = false; }
    }

    public ShellyConfig LoadConfig()
    {
        try
        {
            if (_config != null)
            {
                return _config;
            }

            if (!File.Exists(ConfigPath)) return new ShellyConfig();

            var json = File.ReadAllText(ConfigPath);
            Console.WriteLine(ConfigPath);
            _config = JsonSerializer.Deserialize(json, ShellyGtkJsonContext.Default.ShellyConfig) ?? new ShellyConfig();

            // Safeguard: if DefaultView is ShellySearch but ShellySearch is disabled, fall back to packages.
            if (_config.DefaultView == nameof(Shelly.Gtk.Enums.DefaultViewEnum.ShellySearch) && !_config.ShellySearchEnabled)
            {
                _config.DefaultView = nameof(Shelly.Gtk.Enums.DefaultViewEnum.HomeScreen);
            }

            return _config;
        }
        catch
        {
            return new ShellyConfig();
        }
    }

    private static void CallCliConfigSet(string key, string value)
    {
        try
        {
            var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = FindCliPath(),
                    Arguments = $"config set {key} \"{value}\"",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };
            process.Start();
            process.WaitForExit(5000);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Failed to set config via CLI: {key} = {value}: {ex.Message}");
        }
    }

    private static string FindCliPath()
    {
#if DEBUG
        var home = Environment.GetEnvironmentVariable("HOME")
                   ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var debugPath = Path.Combine(home, "RiderProjects/Shelly-ALPM/Shelly-CLI/bin/Debug/net10.0/linux-x64/shelly");
        if (File.Exists(debugPath)) return debugPath;
#endif

        var possiblePaths = new[]
        {
            "/usr/bin/shelly",
            "/usr/local/bin/shelly",
            Path.Combine(AppContext.BaseDirectory, "shelly"),
        };

        foreach (var path in possiblePaths)
        {
            if (File.Exists(path))
                return path;
        }

        return "shelly";
    }
}
