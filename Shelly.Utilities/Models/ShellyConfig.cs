using Shelly.Utilities.Enums;

namespace Shelly.Utilities;

public class ShellyConfig
{
    // Existing CLI settings
    public string FileSizeDisplay { get; set; } = nameof(SizeDisplay.Megabytes);
    public string DefaultExecution { get; set; } = nameof(DefaultCommand.UpgradeAll);

    public int ParallelDownloadCount { get; set; } = 10;

    // Migrated from UI
    public string? AccentColor { get; set; }
    public string? Culture { get; set; }
    public bool DarkMode { get; set; } = true;
    public bool AurEnabled { get; set; }
    public bool ShellySearchEnabled { get; set; }
    public bool AurWarningConfirmed { get; set; }
    public bool FlatPackEnabled { get; set; }
    public bool ConsoleEnabled { get; set; }
    public double WindowWidth { get; set; } = 800;
    public double WindowHeight { get; set; } = 600;
    public string DefaultView { get; set; } = "HomeScreen";
    public bool UseKdeTheme { get; set; }
    public bool UseOldMenu { get; set; }
    public bool TrayEnabled { get; set; } = true;
    public int TrayCheckIntervalHours { get; set; } = 72;
    public bool NoConfirm { get; set; }
    public bool NewInstall { get; set; } = true;
    public string CurrentVersion { get; set; } = "0.0.0.0";
    public bool UseWeeklySchedule { get; set; }
    public List<DayOfWeek> DaysOfWeek { get; set; } = [];
    public TimeOnly? Time { get; set; }
    public bool WebViewEnabled { get; set; }
    public bool ShellyIconsEnabled { get; set; } = true;
    public bool AppImageEnabled { get; set; }
    public bool NewInstallInitSettings { get; set; }
    public bool UseSymbolicTray { get; set; } = true;
    public bool RemoveCache { get; set; }

    public string? TrayIconPath { get; set; }
    public string? TrayUpdatesIconPath { get; set; }

    public ShellyTabs DefaultPageDropDown { get; set; } = ShellyTabs.Packages;

    public bool SuppressFingerprintWarning { get; set; }

    public bool RecommendedEnabled { get; set; }

    public string ProgressBarStyle { get; set; } = nameof(ProgressBarStyleKind.Blocks);
    public int ProgressBarFps { get; set; } = 7;
    public int ProgressBarWidth { get; set; } = 24;

    public string OutputMode { get; set; } = "singlepane";

    public int SinglePaneMaxStickies { get; set; } = 6;

    public bool TrayAutoStart { get; set; }

    public bool PackageDowngradeEnabled { get; set; }

    public bool PackageManagementCascadeDelete { get; set; } = true;
    public bool PackageManagementRemoveConfigs { get; set; }
    public bool PackageManagementRemoveOptionalDeps { get; set; } = true;
    public bool PackageManagementShowHidden { get; set; }
    public bool PackageInstallUpgrade { get; set; }
    public bool PackageInstallShowHidden { get; set; }
    public bool PackageUpdateShowHidden { get; set; }
    public bool AurInstallUseChroot { get; set; }
    public bool AurInstallRunChecks { get; set; }
    public bool AurRemoveCascadeDelete { get; set; } = true;
    public bool AurRemoveShowHidden { get; set; }
    public bool AurUpdateRunChecks { get; set; }
    public bool AurUpdateShowHidden { get; set; }
    
    public string? AppImageInstallPath { get; set; }
}