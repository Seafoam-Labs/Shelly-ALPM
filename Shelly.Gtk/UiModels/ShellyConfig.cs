
using Shelly.Gtk.Enums;

namespace Shelly.Gtk.UiModels;

public class ShellyConfig
{
    public string? AccentColor { get; set; }
    
    public string? Culture {get; set;}
    
    public bool DarkMode { get; set; } = true;

    public bool AurEnabled { get; set; } = false;
    
    public bool ShellySearchEnabled { get; set; } = false;
    
    public bool AurWarningConfirmed { get; set; } = false;
    
    public bool FlatPackEnabled { get; set; } = false;
    
    public bool AppImageEnabled { get; set; } = false;
    
    public bool ConsoleEnabled { get; set; } = false;
    
    public double WindowWidth { get; set; } = 800;
    
    public double WindowHeight { get; set; } = 600;
    
    public string DefaultView { get; set; } = nameof(DefaultViewEnum.HomeScreen);
    
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
    
    public int ParallelDownloadCount { get; set; } = 10;
    
    public bool ShellyIconsEnabled { get; set; } = true;
    
    public bool NewInstallInitSettings { get; set; } = false;
    
    public bool UseSymbolicTray { get; set; } = true;

    public string? TrayIconPath { get; set; }

    public string? TrayUpdatesIconPath { get; set; }
    
    public ShellyTabs DefaultPageDropDown { get; set; } = ShellyTabs.Packages;
    
    // Existing CLI settings (included for unified config compatibility)
    public string FileSizeDisplay { get; set; } = "Bytes";
    public string DefaultExecution { get; set; } = "UpgradeAll";
    public string ProgressBarStyle { get; set; } = nameof(ProgressBarStyleKind.Blocks);
}
