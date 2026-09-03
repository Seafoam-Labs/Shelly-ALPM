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
    TrayEnabled: bool = false,
    TrayAutoStart: bool = false,
    TrayCheckIntervalHours: u32 = 72,
    UseSymbolicTray: bool = true,
    TrayIconPath: []const u8 = "",
    TrayUpdatesIconPath: []const u8 = "",
    UseWeeklySchedule: bool = false,
    TrayRunAsCron: bool = false,
    DaysOfWeek: []const DayOfWeek = &.{},
    UseUiForUpdate: bool = false,
    Time: []const u8 = "",
};
