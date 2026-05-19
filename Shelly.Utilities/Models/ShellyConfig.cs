using Shelly.Utilities.Enums;

namespace Shelly.Utilities;

public class ShellyConfig
{
    // Existing CLI settings
    public string FileSizeDisplay { get; set; } = nameof(SizeDisplay.Bytes);
    public string DefaultExecution { get; set; } = nameof(DefaultCommand.UpgradeAll);

    public int ParallelDownloadCount { get; set; } = 10;

    // Migrated from UI
    public string? AccentColor { get; set; }
    public string? Culture { get; set; }
    public bool DarkMode { get; set; } = true;
    public bool AurEnabled { get; set; } = false;
    public bool ShellySearchEnabled { get; set; } = false;
    public bool AurWarningConfirmed { get; set; } = false;
    public bool FlatPackEnabled { get; set; } = false;
    public bool ConsoleEnabled { get; set; } = false;
    public double WindowWidth { get; set; } = 800;
    public double WindowHeight { get; set; } = 600;
    public string DefaultView { get; set; } = "HomeScreen";
    public bool UseKdeTheme { get; set; } = false;
    public bool UseOldMenu { get; set; } = false;
    public bool TrayEnabled { get; set; } = true;
    public int TrayCheckIntervalHours { get; set; } = 12;
    public bool NoConfirm { get; set; } = false;
    public bool NewInstall { get; set; } = true;
    public string CurrentVersion { get; set; } = "0.0.0";
    public bool UseWeeklySchedule { get; set; } = false;
    public List<DayOfWeek> DaysOfWeek { get; set; } = [];
    public TimeOnly? Time { get; set; } = null;
    public bool WebViewEnabled { get; set; } = false;
    public bool ShellyIconsEnabled { get; set; } = true;
    public bool AppImageEnabled { get; set; } = false;
    public bool NewInstallInitSettings { get; set; } = false;
    public bool UseSymbolicTray { get; set; } = true;

    public string? TrayIconPath { get; set; }
    public string? TrayUpdatesIconPath { get; set; }
    
    public ShellyTabs DefaultPageDropDown { get; set; } = ShellyTabs.Packages;

    public bool SuppressFingerprintWarning { get; set; } = false;

    public bool RecommendedEnabled { get; set; } = false;
    
    public string ProgressBarStyle { get; set; } = nameof(ProgressBarStyleKind.Blocks);
    public int ProgressBarFps { get; set; } = 7;
    public int ProgressBarWidth { get; set; } = 24;
    
    public string OutputMode { get; set; } = "singlepane";
    
    public int SinglePaneMaxStickies { get; set; } = 6;
    
    public bool TrayAutoStart { get; set; } = false;
}