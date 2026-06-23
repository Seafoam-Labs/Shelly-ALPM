using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Shelly.Gtk.Helpers;
using Shelly.Utilities;

namespace Shelly.Gtk.Services;

public class ConfigService : IConfigService
{
    private static readonly string ConfigFolder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "shelly");

    private static readonly string ConfigPath = Path.Combine(ConfigFolder, "config.json");

    private ShellyConfig? _config;
    private readonly IDirtyService _dirtyService;
    private bool _suppressInvalidate;

    public ConfigService(IDirtyService dirtyService)
    {
        _dirtyService = dirtyService;
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
        
        CallCliConfigSet(nameof(config.Culture), config.Culture ?? "");
        CallCliConfigSet(nameof(config.AurEnabled), config.AurEnabled.ToString());
        CallCliConfigSet(nameof(config.ShellySearchEnabled), config.ShellySearchEnabled.ToString());
        CallCliConfigSet(nameof(config.AurWarningConfirmed), config.AurWarningConfirmed.ToString());
        CallCliConfigSet(nameof(config.FlatPackEnabled), config.FlatPackEnabled.ToString());
        CallCliConfigSet(nameof(config.AppImageEnabled), config.AppImageEnabled.ToString());
        CallCliConfigSet(nameof(config.WindowWidth), config.WindowWidth.ToString(CultureInfo.InvariantCulture));
        CallCliConfigSet(nameof(config.WindowHeight), config.WindowHeight.ToString(CultureInfo.InvariantCulture));
        CallCliConfigSet(nameof(config.DefaultView), config.DefaultView);
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
        CallCliConfigSet(nameof(config.RecommendedEnabled), config.RecommendedEnabled.ToString());
        CallCliConfigSet(nameof(config.FileSizeDisplay), config.FileSizeDisplay);
        CallCliConfigSet(nameof(config.DefaultExecution), config.DefaultExecution);
        CallCliConfigSet(nameof(config.ParallelDownloadCount), config.ParallelDownloadCount.ToString());
        CallCliConfigSet(nameof(config.UseSymbolicTray), config.UseSymbolicTray.ToString());
        CallCliConfigSet(nameof(config.TrayIconPath), config.TrayIconPath ?? "");
        CallCliConfigSet(nameof(config.TrayUpdatesIconPath), config.TrayUpdatesIconPath ?? "");
        CallCliConfigSet(nameof(config.DefaultPageDropDown), config.DefaultPageDropDown.ToString());
        CallCliConfigSet(nameof(config.SuppressFingerprintWarning), config.SuppressFingerprintWarning.ToString());
        CallCliConfigSet(nameof(config.RemoveCache), config.RemoveCache.ToString());
        CallCliConfigSet(nameof(config.TrayAutoStart), config.TrayAutoStart.ToString());
        CallCliConfigSet(nameof(config.PackageDowngradeEnabled), config.PackageDowngradeEnabled.ToString());
        CallCliConfigSet(nameof(config.PackageManagementCascadeDelete),
            config.PackageManagementCascadeDelete.ToString());
        CallCliConfigSet(nameof(config.PackageManagementRemoveConfigs),
            config.PackageManagementRemoveConfigs.ToString());
        CallCliConfigSet(nameof(config.PackageManagementRemoveOptionalDeps),
            config.PackageManagementRemoveOptionalDeps.ToString());
        CallCliConfigSet(nameof(config.PackageManagementShowHidden), config.PackageManagementShowHidden.ToString());
        CallCliConfigSet(nameof(config.PackageInstallUpgrade), config.PackageInstallUpgrade.ToString());
        CallCliConfigSet(nameof(config.PackageInstallShowHidden), config.PackageInstallShowHidden.ToString());
        CallCliConfigSet(nameof(config.PackageUpdateShowHidden), config.PackageUpdateShowHidden.ToString());
        CallCliConfigSet(nameof(config.AurInstallUseChroot), config.AurInstallUseChroot.ToString());
        CallCliConfigSet(nameof(config.AurInstallRunChecks), config.AurInstallRunChecks.ToString());
        CallCliConfigSet(nameof(config.AurRemoveCascadeDelete), config.AurRemoveCascadeDelete.ToString());
        CallCliConfigSet(nameof(config.AurRemoveShowHidden), config.AurRemoveShowHidden.ToString());
        CallCliConfigSet(nameof(config.AurUpdateRunChecks), config.AurUpdateRunChecks.ToString());
        CallCliConfigSet(nameof(config.AurUpdateShowHidden), config.AurUpdateShowHidden.ToString());
        CallCliConfigSet(nameof(config.AppImageInstallPath), config.AppImageInstallPath ?? "");
        CallCliConfigSet(nameof(config.PackageInstallView), config.PackageInstallView.ToString());
        CallCliConfigSet(nameof(config.PackageInstallUpgrade), config.PackageInstallUpgrade.ToString());
        CallCliConfigSet(nameof(config.PackageManageView), config.PackageManageView.ToString());
        ConfigSaved?.Invoke(this, config);
        _suppressInvalidate = true;
        try
        {
            _dirtyService.MarkDirty(DirtyScopes.Config);
        }
        finally
        {
            _suppressInvalidate = false;
        }
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
            if (_config.DefaultView == nameof(Enums.DefaultViewEnum.ShellySearch) && !_config.ShellySearchEnabled)
            {
                _config.DefaultView = nameof(Enums.DefaultViewEnum.HomeScreen);
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
                    FileName = CliPathResolver.FindCliPath(),
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
}