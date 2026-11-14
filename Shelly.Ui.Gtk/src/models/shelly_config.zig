pub const ViewType = enum(u8) {
    grid = 0,
    list = 1,
};

pub const NavMode = enum(u8) {
    sidebar = 0,
    topbar = 1,
};

/// Which paint the UI uses: the built-in Pearl-style theme or the desktop's
/// GTK theme. `system` reproduces the pre-theme rendering exactly.
pub const ThemeMode = enum(u8) {
    shelly = 0,
    system = 1,
};

/// Color variant for the built-in theme; `follow_system` tracks the desktop's
/// dark/light preference. In `system` mode it only sets the dark preference.
pub const ThemeVariant = enum(u8) {
    follow_system = 0,
    dark = 1,
    light = 2,
};

pub const ShellyTabs = enum(u8) {
    packages = 0,
    aur = 1,
    flatpak = 2,
    app_image = 3,
    shelly_search = 4,
    recommend = 5,
    update = 6,
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
    NoConfirm: bool = false,

    // Feature Toggles
    AurEnabled: bool = false,
    AurWarningConfirmed: bool = false,
    AtollAurEnabled: bool = false,
    AppImageEnabled: bool = false,
    FlatPackEnabled: bool = false,
    RecommendedEnabled: bool = true,
    ShellyIconsEnabled: bool = true,
    ShellySearchEnabled: bool = false,

    // Window & View
    DefaultPageDropDown: ShellyTabs = .packages,
    NavMode: NavMode = .sidebar,
    ThemeMode: ThemeMode = .shelly,
    ThemeVariant: ThemeVariant = .follow_system,
    // Internal: persisted window geometry, not exposed in settings UI
    WindowLastWidth: i32 = 0,
    WindowLastHeight: i32 = 0,

    // Package Page
    PackageInstallView: ViewType = .grid,

    PackageManagementCascadeDelete: bool = true,
    PackageManagementRemoveConfigs: bool = false,
    PackageManagementRemoveOptionalDeps: bool = true,

    PackageInstallUpgrade: bool = false,
    PackageInstallShowHidden: bool = false,
    PackageInstallShowExplicitOnly: bool = false,
    PackageInstallShowDependsOnly: bool = false,
    PackageInstallShowDetailPane: bool = false,

    // AUR Page
    AurInstallUseChroot: bool = false,
    AurInstallRunChecks: bool = false,
    AurInstallShowDetailPane: bool = false,
    AurInstallDisableDevel: bool = false,

    AurRemoveCascadeDelete: bool = true,

    AurUpdateRunChecks: bool = false,
    AurUpdateShowHidden: bool = false,

    // Search Page
    SearchShowDetailPane: bool = false,

    // Tray
    TrayEnabled: bool = false,
    TrayAutoStart: bool = false,
    TrayCheckIntervalHours: i32 = 72,
    UseSymbolicTray: bool = true,
    TrayIconPath: []const u8 = "",
    TrayUpdatesIconPath: []const u8 = "",
    UseUiForUpdate: bool = false,
    TerminalForUpdate: []const u8 = "",

    // Scheduled Operations
    UseWeeklySchedule: bool = false,
    TrayRunAsCron: bool = true,
    DaysOfWeek: []const DayOfWeek = &.{},
    Time: []const u8 = "",
};
