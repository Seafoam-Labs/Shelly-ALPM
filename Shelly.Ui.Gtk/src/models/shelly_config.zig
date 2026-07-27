pub const ViewType = enum(u8) {
    grid = 0,
    list = 1,
};

pub const ShellyTabs = enum(u8) {
    packages = 0,
    aur = 1,
    flatpak = 2,
    app_image = 3,
    shelly_search = 4,
    recommend = 5,
};

pub const DayOfWeek = enum(u8) {
    sunday = 0,
    monday = 1,
    tuesday = 2,
    wednesday = 3,
    thursday = 4,
    friday = 5,
    saturday = 6,
};

pub const ShellyConfig = struct {
    // General
    Culture: []const u8 = "",
    NewInstall: bool = true,
    NewInstallInitSettings: bool = false,
    NoConfirm: bool = false,

    // Feature Toggles
    AurEnabled: bool = false,
    AurWarningConfirmed: bool = false,
    AppImageEnabled: bool = false,
    AppImageInstallPath: []const u8 = "",
    FlatPackEnabled: bool = false,
    PackageDowngradeEnabled: bool = false,
    RecommendedEnabled: bool = true,
    ShellyIconsEnabled: bool = true,
    ShellySearchEnabled: bool = false,
    WebviewEnabled: bool = false,

    // Window & View
    DefaultPageDropDown: ShellyTabs = .packages,

    // Package Page
    PackageInstallView: ViewType = .list,

    PackageManagementCascadeDelete: bool = true,
    PackageManagementRemoveConfigs: bool = false,
    PackageManagementRemoveOptionalDeps: bool = true,
    PackageManagementShowHidden: bool = false,

    PackageInstallUpgrade: bool = false,
    PackageInstallShowHidden: bool = false,
    PackageInstallShowExplicitOnly: bool = false,
    PackageInstallShowDetailPane: bool = false,

    // AUR Page
    AurInstallUseChroot: bool = false,
    AurInstallRunChecks: bool = false,

    AurRemoveCascadeDelete: bool = true,
    AurRemoveShowHidden: bool = false,

    AurUpdateRunChecks: bool = false,
    AurUpdateShowHidden: bool = false,

    // Tray
    TrayEnabled: bool = true,
    TrayAutoStart: bool = false,
    TrayCheckIntervalHours: i32 = 72,
    UseSymbolicTray: bool = true,
    TrayIconPath: []const u8 = "",
    TrayUpdatesIconPath: []const u8 = "",

    // Scheduled Operations
    UseWeeklySchedule: bool = false,
    DaysOfWeek: []const DayOfWeek = &.{},
    Time: []const u8 = "",
};
