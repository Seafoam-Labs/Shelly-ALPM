//! Groups the flat Flatpak permission tokens the backend emits into one row per
//! concern, and works out how much each row should worry the reader.
//!
//! The backend emits one `{group}={key}:{value}` string per individual token, so
//! a filesystem-heavy app arrives as sixteen strings that differ only by folder
//! name. Every consumer needs the same answer to "what does this ask for", so
//! the grouping, the risk tiering, and the interpretation of the structure
//! inside a value (access modes, `!` denials, `if:` conditions) live here
//! instead of in each surface.
//!
//! The split mirrors `appendPermission` in
//! `Shelly.Flatpak.Backend/src/flatpak/manager.zig`: first `=`, then the first
//! `:` after it, everything remaining is the value. Widen one and you must widen
//! the other; the backend's `parity-test` fixtures pin that format.

const std = @import("std");

/// One row of a permission list. Declaration order is the tie-break inside a
/// risk tier, so the concerns that matter most come first.
pub const Concern = enum {
    files_system,
    files_paths,
    files_runtime,
    files_config,
    files_home,
    files_user_dirs,
    files_persistent,
    devices,
    session_bus,
    system_bus,
    network,
    display,
    features,
    environment,
    audio,
    printing,
    ipc,
    other,

    /// The English wording, shared by every surface that does not translate.
    /// `Shelly.Ui.Gtk` keeps its own `_()` table keyed on the same tag names so
    /// its strings stay extractable by gettext; change the two together.
    pub fn label(self: Concern) [:0]const u8 {
        return switch (self) {
            .files_system => "System files",
            .files_paths => "Other folders",
            .files_runtime => "Running services",
            .files_config => "Other apps' data",
            .files_home => "Home folder",
            .files_user_dirs => "User folders",
            .files_persistent => "Persistent files",
            .devices => "Devices",
            .session_bus => "Session bus",
            .system_bus => "System bus",
            .network => "Network access",
            .display => "Display server",
            .features => "Sandbox features",
            .environment => "Environment",
            .audio => "Sound",
            .printing => "Printing",
            .ipc => "Inter-process communication",
            .other => "Other",
        };
    }

    /// Wording for a row stating an access the app does not ask for. A concern
    /// with no answer here never produces an absence row.
    pub fn absenceLabel(self: Concern) ?[:0]const u8 {
        return switch (self) {
            .network => "No network access",
            .devices => "No device access",
            .files_system => "No access to system files",
            else => null,
        };
    }
};

/// How much a row should stand out. Surfaces choose colour and icon from it.
pub const Tier = enum {
    /// Reaches the rest of the session, the system, or another app's data.
    high,
    /// A normal capability that still leaves the sandbox.
    medium,
    /// Narrow, or something the app handed back.
    low,

    fn rank(self: Tier) u8 {
        return switch (self) {
            .low => 0,
            .medium => 1,
            .high => 2,
        };
    }
};

pub const State = enum {
    /// The app asked for this. Also covers a denial, which is the app asking
    /// for *less* than its runtime grants it: the item text says which.
    granted,
    /// The app does not ask for this at all. Stated so a list can reassure as
    /// well as warn, the way Flathub's "No user device access" row does.
    absent,
};

pub const Row = struct {
    concern: Concern,
    tier: Tier,
    state: State,
    /// Detail lines: folder names, device names, service names. Empty when the
    /// concern label already says everything there is to say.
    items: []const []const u8,
};

pub const Summary = struct {
    rows: []Row,
    /// Entries that did not look like `{group}={key}:{value}` at all. A caller
    /// that asked for permissions and got only these back has not read them, so
    /// it must not claim the app requested nothing.
    malformed: usize,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        freeRows(allocator, self.rows);
        self.* = undefined;
    }
};

pub fn freeRows(allocator: std.mem.Allocator, rows: []const Row) void {
    for (rows) |row| {
        for (row.items) |item| allocator.free(item);
        allocator.free(row.items);
    }
    allocator.free(rows);
}

const context_group = "Context";
const session_bus_group = "Session Bus Policy";
const system_bus_group = "System Bus Policy";
const environment_group = "Environment";

/// Splits `{group}={key}:{value}`. Values run to the end of the string, so
/// `host:ro` and `if:x11:!has-wayland` keep their own colons.
const Entry = struct {
    group: []const u8,
    key: []const u8,
    value: []const u8,
};

fn splitEntry(raw: []const u8) ?Entry {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return null;
    const rest = raw[eq + 1 ..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const group = raw[0..eq];
    const key = rest[0..colon];
    const value = rest[colon + 1 ..];
    if (group.len == 0 or key.len == 0 or value.len == 0) return null;
    return .{ .group = group, .key = key, .value = value };
}

/// A permission token with its wrappers taken off: `!x11` denies `x11`, and
/// `if:x11:!has-wayland` conditionally grants `x11`.
const Token = struct {
    /// As it arrived, so an unknown token can still be shown verbatim.
    raw: []const u8,
    /// What the token is about, once `!` and `if:` are removed.
    name: []const u8,
    denied: bool = false,
    condition: ?[]const u8 = null,
    mode: Mode = .read_write,
    /// Filesystem grants leave read/write implied when the metadata says
    /// nothing, and "Downloads" means something different once the direction is
    /// spelled out. Keys with no mode to read never set this.
    show_mode: bool = false,

    fn parse(raw: []const u8) Token {
        var token = Token{ .raw = raw, .name = raw };
        if (std.mem.startsWith(u8, token.name, "!")) {
            token.denied = true;
            token.name = token.name[1..];
        }
        if (std.mem.startsWith(u8, token.name, "if:")) {
            const inner = token.name[3..];
            const colon = std.mem.indexOfScalar(u8, inner, ':') orelse {
                token.name = inner;
                return token;
            };
            token.condition = inner[colon + 1 ..];
            token.name = inner[0..colon];
        }
        // `if:!perm` puts the denial inside the wrapper rather than outside it.
        if (std.mem.startsWith(u8, token.name, "!")) {
            token.denied = true;
            token.name = token.name[1..];
        }
        return token;
    }
};

const Mode = enum { read_only, read_write, create };

/// Strips a `:ro`/`:rw`/`:create` suffix. Only `[Context] filesystems` tokens
/// carry one; applying it to the rest keeps the tables short and costs nothing.
const Suffixed = struct {
    name: []const u8,
    mode: Mode,
};

fn takeMode(name: []const u8) Suffixed {
    if (std.mem.endsWith(u8, name, ":ro")) return .{ .name = name[0 .. name.len - 3], .mode = .read_only };
    if (std.mem.endsWith(u8, name, ":rw")) return .{ .name = name[0 .. name.len - 3], .mode = .read_write };
    if (std.mem.endsWith(u8, name, ":create")) return .{ .name = name[0 .. name.len - 7], .mode = .create };
    return .{ .name = name, .mode = .read_write };
}

/// Accumulates everything destined for one concern while the entries are walked.
const Bucket = struct {
    items: std.ArrayList([]const u8) = .empty,
    tier: Tier = .low,
    /// The app said something about this concern, grant or denial, so no
    /// absence row is needed for it.
    mentioned: bool = false,
    /// Only a plain or conditional grant sets this. A concern holding nothing
    /// but denials is not risky.
    granted: bool = false,
    absent: bool = false,
};

const Buckets = [std.meta.fields(Concern).len]Bucket;

pub fn classify(allocator: std.mem.Allocator, entries: []const []const u8) !Summary {
    var buckets: Buckets = @splat(.{});
    // `collectRows` moves each bucket's items into the rows it returns, so on
    // the way out anything still in a bucket is only left over because of an
    // error partway through.
    errdefer freeItems(allocator, &buckets);

    var malformed: usize = 0;
    for (entries) |raw| {
        const entry = splitEntry(raw) orelse {
            malformed += 1;
            continue;
        };
        if (std.mem.eql(u8, entry.group, context_group)) {
            try classifyContext(allocator, &buckets, entry.key, entry.value);
        } else if (std.mem.eql(u8, entry.group, session_bus_group) or
            std.mem.eql(u8, entry.group, system_bus_group))
        {
            try classifyBusPolicy(allocator, &buckets, entry, std.mem.eql(u8, entry.group, system_bus_group));
        } else if (std.mem.eql(u8, entry.group, environment_group)) {
            // Here the axes are a variable and its value rather than a
            // capability and a token, so the pair is the whole item.
            try addTextItem(allocator, &buckets, .environment, .low, try std.fmt.allocPrint(
                allocator,
                "{s}={s}",
                .{ entry.key, entry.value },
            ));
        } else {
            // An unrecognised group still gets a row. Dropping it silently is
            // how the D-Bus and environment grants disappeared once already.
            try addTextItem(allocator, &buckets, .other, .medium, try std.fmt.allocPrint(
                allocator,
                "{s} {s}={s}",
                .{ entry.group, entry.key, entry.value },
            ));
        }
    }

    addAbsences(&buckets);
    return .{
        .rows = try collectRows(allocator, &buckets),
        .malformed = malformed,
    };
}

fn bucket(buckets: *Buckets, concern: Concern) *Bucket {
    return &buckets[@intFromEnum(concern)];
}

fn freeItems(allocator: std.mem.Allocator, buckets: *Buckets) void {
    for (buckets) |*b| {
        for (b.items.items) |item| allocator.free(item);
        b.items.deinit(allocator);
    }
}

fn addGrant(buckets: *Buckets, concern: Concern, tier: Tier) void {
    const b = bucket(buckets, concern);
    b.mentioned = true;
    b.granted = true;
    if (tier.rank() > b.tier.rank()) b.tier = tier;
}

/// A detail line the tables cannot describe on their own: an unknown token, a
/// removed variable, a D-Bus name.
fn addTextItem(allocator: std.mem.Allocator, buckets: *Buckets, concern: Concern, tier: Tier, text: []const u8) !void {
    const b = bucket(buckets, concern);
    try b.items.append(allocator, text);
    addGrant(buckets, concern, tier);
}

/// Records one token against a concern. `label` is the wording for the detail
/// line, or null when the concern label is the whole story (`shared=network`).
/// A denial or a condition always needs a line, because the bare label would
/// read as a plain grant.
fn addToken(
    allocator: std.mem.Allocator,
    buckets: *Buckets,
    concern: Concern,
    tier: Tier,
    label: ?[]const u8,
    token: Token,
) !void {
    const b = bucket(buckets, concern);
    b.mentioned = true;
    if (label != null or token.condition != null or token.denied) {
        try b.items.append(allocator, try itemText(allocator, label orelse token.name, token));
    }
    if (token.denied) return;
    b.granted = true;
    if (tier.rank() > b.tier.rank()) b.tier = tier;
}

fn classifyContext(
    allocator: std.mem.Allocator,
    buckets: *Buckets,
    key: []const u8,
    value: []const u8,
) !void {
    // The backend splits list values already, so this normally sees one token.
    // Splitting again covers the fallback to `g_key_file_get_string`, where a
    // `;` would otherwise smuggle two grants into one row.
    var iterator = std.mem.splitScalar(u8, value, ';');
    while (iterator.next()) |part| {
        if (part.len == 0) continue;
        const token = Token.parse(part);
        if (std.mem.eql(u8, key, "filesystems")) {
            try classifyFilesystemToken(allocator, buckets, token);
        } else if (std.mem.eql(u8, key, "shared")) {
            try classifyByTable(allocator, buckets, &shared_tokens, token);
        } else if (std.mem.eql(u8, key, "sockets")) {
            try classifyByTable(allocator, buckets, &socket_tokens, token);
        } else if (std.mem.eql(u8, key, "devices")) {
            try classifyByTable(allocator, buckets, &device_tokens, token);
        } else if (std.mem.eql(u8, key, "features")) {
            try classifyByTable(allocator, buckets, &feature_tokens, token);
        } else if (std.mem.eql(u8, key, "persistent")) {
            // Binds a folder of the app's own directory into the sandbox home,
            // where it outlives the app and its data.
            try addTextItem(allocator, buckets, .files_persistent, .low, try std.fmt.allocPrint(
                allocator,
                "{s} (kept after uninstall)",
                .{token.name},
            ));
        } else if (std.mem.eql(u8, key, "unset-environment")) {
            try addTextItem(allocator, buckets, .environment, .low, try std.fmt.allocPrint(
                allocator,
                "{s} (removed)",
                .{token.name},
            ));
        } else {
            try addTextItem(allocator, buckets, .other, .medium, try std.fmt.allocPrint(
                allocator,
                "{s}={s}",
                .{ key, token.raw },
            ));
        }
    }
}

const TokenRule = struct {
    name: []const u8,
    concern: Concern,
    tier: Tier,
    /// Wording for the detail line, or null when the concern label describes
    /// the grant completely.
    label: ?[]const u8 = null,
};

fn classifyByTable(
    allocator: std.mem.Allocator,
    buckets: *Buckets,
    rules: []const TokenRule,
    token: Token,
) !void {
    for (rules) |rule| {
        if (!std.mem.eql(u8, rule.name, token.name)) continue;
        try addToken(allocator, buckets, rule.concern, rule.tier, rule.label, token);
        return;
    }
    // New upstream vocabulary: keep it under the concern the app was talking
    // about rather than hiding it, and do not assume it is harmless.
    try addToken(allocator, buckets, sharedConcern(rules) orelse .other, .medium, token.name, token);
}

/// The concern a table is about, when every one of its rules agrees.
fn sharedConcern(rules: []const TokenRule) ?Concern {
    if (rules.len == 0) return null;
    for (rules) |rule| {
        if (rule.concern != rules[0].concern) return null;
    }
    return rules[0].concern;
}

const shared_tokens = [_]TokenRule{
    .{ .name = "network", .concern = .network, .tier = .medium },
    .{ .name = "ipc", .concern = .ipc, .tier = .low },
};

const socket_tokens = [_]TokenRule{
    // X11 has no per-client isolation: any X11 client can read the rest of the
    // session. Wayland does, so the two are not the same grant.
    .{ .name = "x11", .concern = .display, .tier = .high, .label = "X11" },
    .{ .name = "fallback-x11", .concern = .display, .tier = .high, .label = "X11" },
    .{ .name = "wayland", .concern = .display, .tier = .medium, .label = "Wayland" },
    .{ .name = "inherit-wayland-socket", .concern = .display, .tier = .low, .label = "the parent's Wayland socket" },
    .{ .name = "pulseaudio", .concern = .audio, .tier = .medium },
    .{ .name = "cups", .concern = .printing, .tier = .medium },
    // `session-bus` and `system-bus` are values of `sockets=`, not categories of
    // their own, and they mean the whole bus rather than one named service.
    .{ .name = "session-bus", .concern = .session_bus, .tier = .high, .label = "full session bus access" },
    .{ .name = "system-bus", .concern = .system_bus, .tier = .high, .label = "full system bus access" },
    .{ .name = "ssh-auth", .concern = .devices, .tier = .medium, .label = "SSH keys" },
    .{ .name = "gpg-agent", .concern = .devices, .tier = .medium, .label = "GPG keys" },
    .{ .name = "pcsc", .concern = .devices, .tier = .medium, .label = "smartcard reader" },
};

const device_tokens = [_]TokenRule{
    .{ .name = "all", .concern = .devices, .tier = .high, .label = "every device node" },
    .{ .name = "kvm", .concern = .devices, .tier = .high, .label = "virtualisation (KVM)" },
    .{ .name = "input", .concern = .devices, .tier = .high, .label = "keyboard and mouse (/dev/input)" },
    .{ .name = "usb", .concern = .devices, .tier = .medium, .label = "USB devices" },
    .{ .name = "dri", .concern = .devices, .tier = .low, .label = "graphics acceleration (DRI)" },
    .{ .name = "shm", .concern = .devices, .tier = .low, .label = "shared memory (/dev/shm)" },
};

const feature_tokens = [_]TokenRule{
    .{ .name = "devel", .concern = .features, .tier = .high, .label = "debugging and profiling syscalls" },
    .{ .name = "bluetooth", .concern = .features, .tier = .medium, .label = "Bluetooth" },
    .{ .name = "canbus", .concern = .features, .tier = .medium, .label = "CAN bus" },
    .{ .name = "multiarch", .concern = .features, .tier = .low, .label = "foreign-architecture code" },
    .{ .name = "per-app-dev-shm", .concern = .features, .tier = .low, .label = "a private /dev/shm" },
};

/// `[Session Bus Policy]` and `[System Bus Policy]` key a D-Bus name or prefix,
/// an open vocabulary that includes `*` wildcards, so the value is an access
/// level rather than a capability token. Nothing reaches the system bus by
/// default, which is why the same level reads as worse there.
fn classifyBusPolicy(
    allocator: std.mem.Allocator,
    buckets: *Buckets,
    entry: Entry,
    system: bool,
) !void {
    const tier: Tier = if (std.mem.eql(u8, entry.value, "own"))
        .high
    else if (std.mem.eql(u8, entry.value, "talk"))
        (if (system) Tier.high else Tier.medium)
    else if (std.mem.eql(u8, entry.value, "see"))
        (if (system) Tier.medium else Tier.low)
    else
        Tier.low;
    try addTextItem(allocator, buckets, if (system) Concern.system_bus else Concern.session_bus, tier, try std.fmt.allocPrint(
        allocator,
        "{s} ({s})",
        .{ entry.key, entry.value },
    ));
}

const FilesystemRule = struct {
    name: []const u8,
    concern: Concern,
    tier: Tier,
    label: []const u8,
};

const filesystem_tokens = [_]FilesystemRule{
    .{ .name = "host", .concern = .files_system, .tier = .high, .label = "the whole filesystem" },
    .{ .name = "host-root", .concern = .files_system, .tier = .high, .label = "the whole filesystem" },
    .{ .name = "host-etc", .concern = .files_system, .tier = .medium, .label = "system configuration in /etc" },
    .{ .name = "host-os", .concern = .files_system, .tier = .low, .label = "system programs in /usr" },
    .{ .name = "xdg-config", .concern = .files_config, .tier = .high, .label = "every app's settings in ~/.config" },
    .{ .name = "xdg-data", .concern = .files_config, .tier = .high, .label = "every app's data in ~/.local/share" },
    .{ .name = "xdg-cache", .concern = .files_config, .tier = .medium, .label = "every app's cache in ~/.cache" },
    .{ .name = "home", .concern = .files_home, .tier = .medium, .label = "Home folder" },
    .{ .name = "~", .concern = .files_home, .tier = .medium, .label = "Home folder" },
    .{ .name = "xdg-desktop", .concern = .files_user_dirs, .tier = .medium, .label = "Desktop" },
    .{ .name = "xdg-documents", .concern = .files_user_dirs, .tier = .medium, .label = "Documents" },
    .{ .name = "xdg-download", .concern = .files_user_dirs, .tier = .medium, .label = "Downloads" },
    .{ .name = "xdg-music", .concern = .files_user_dirs, .tier = .medium, .label = "Music" },
    .{ .name = "xdg-pictures", .concern = .files_user_dirs, .tier = .medium, .label = "Pictures" },
    .{ .name = "xdg-videos", .concern = .files_user_dirs, .tier = .medium, .label = "Videos" },
    .{ .name = "xdg-public-share", .concern = .files_user_dirs, .tier = .medium, .label = "Public Share" },
    .{ .name = "xdg-templates", .concern = .files_user_dirs, .tier = .low, .label = "Templates" },
};

fn classifyFilesystemToken(
    allocator: std.mem.Allocator,
    buckets: *Buckets,
    token: Token,
) !void {
    const suffixed = takeMode(token.name);
    var resolved = token;
    resolved.name = suffixed.name;
    resolved.mode = suffixed.mode;
    // A removal is about the access, not its direction: "X11 (not granted)"
    // needs no mode next to it.
    resolved.show_mode = !token.denied;

    for (filesystem_tokens) |rule| {
        if (!std.mem.eql(u8, rule.name, resolved.name)) continue;
        try addToken(allocator, buckets, rule.concern, demote(rule.tier, suffixed.mode), rule.label, resolved);
        return;
    }

    // A subpath keeps its parent's concern but is shown verbatim, because the
    // path is the news: `xdg-run/keyring` reaches a secrets service while
    // `xdg-desktop/wallpapers` does not.
    var concern: Concern = .files_paths;
    var tier: Tier = .high;
    for (filesystem_tokens) |rule| {
        if (!std.mem.startsWith(u8, resolved.name, rule.name)) continue;
        if (resolved.name.len <= rule.name.len or resolved.name[rule.name.len] != '/') continue;
        concern = rule.concern;
        // One folder inside a tree is not the whole tree: `xdg-config/GIMP` is
        // narrower than `xdg-config`, which is what makes the latter alarming.
        tier = narrow(rule.tier);
        break;
    }
    if (std.mem.startsWith(u8, resolved.name, "xdg-run/")) {
        concern = .files_runtime;
        tier = .high;
    } else if (concern == .files_paths and !(std.mem.startsWith(u8, resolved.name, "/") or
        std.mem.startsWith(u8, resolved.name, "~/")))
    {
        // Neither a known keyword nor a path: do not alarm, do not hide.
        tier = .medium;
    }
    try addToken(allocator, buckets, concern, demote(tier, suffixed.mode), resolved.name, resolved);
}

/// A grant over part of a tree is not the grant the whole tree would be.
fn narrow(tier: Tier) Tier {
    return switch (tier) {
        .high => .medium,
        else => tier,
    };
}

/// Reading is strictly weaker than writing, and `:create` sits between them: it
/// cannot change what is already there.
fn demote(tier: Tier, mode: Mode) Tier {
    if (mode != .read_only) return tier;
    return switch (tier) {
        .high => .medium,
        .medium => .low,
        .low => .low,
    };
}

/// Composes the detail line: `Downloads (read-only)`, `X11 (not granted)`,
/// `X11 (only when Wayland is not running)`.
fn itemText(allocator: std.mem.Allocator, name: []const u8, token: Token) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(name);

    var qualifiers: usize = 0;
    if (token.denied) qualifiers += 1;
    if (token.mode != .read_write or token.show_mode) qualifiers += 1;
    if (token.condition != null) qualifiers += 1;
    if (qualifiers == 0) return out.toOwnedSlice();

    try out.writer.writeAll(" (");
    var written: usize = 0;
    if (token.denied) {
        try out.writer.writeAll("not granted");
        written += 1;
    }
    if (token.mode != .read_write or token.show_mode) {
        if (written > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(switch (token.mode) {
            .read_only => "read-only",
            .read_write => "read/write",
            .create => "read/write, may create",
        });
        written += 1;
    }
    if (token.condition) |condition| {
        if (written > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(try conditionPhrase(allocator, condition));
    }
    try out.writer.writeByte(')');
    return out.toOwnedSlice();
}

/// flatpak 1.17 conditional permissions: `if:PERMISSION:CONDITION`, where the
/// condition itself may be negated with `!`.
fn conditionPhrase(allocator: std.mem.Allocator, condition: []const u8) ![]const u8 {
    const Known = struct { name: []const u8, holds: []const u8, absent: []const u8 };
    const known = [_]Known{
        .{ .name = "true", .holds = "always", .absent = "never" },
        .{ .name = "false", .holds = "never", .absent = "always" },
        .{ .name = "has-wayland", .holds = "only when Wayland is running", .absent = "only when Wayland is not running" },
        .{ .name = "has-input-device", .holds = "only when an input device is present", .absent = "only when no input device is present" },
        .{ .name = "has-usb-device", .holds = "only when a matching USB device is attached", .absent = "only when no matching USB device is attached" },
        .{ .name = "has-usb-portal", .holds = "only when the USB portal is available", .absent = "only when the USB portal is unavailable" },
    };

    var negated = false;
    var name = condition;
    if (std.mem.startsWith(u8, name, "!")) {
        negated = true;
        name = name[1..];
    }
    for (known) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        return if (negated) entry.absent else entry.holds;
    }
    // A condition flatpak added since this table was written still has to say
    // which way round it applies.
    return std.fmt.allocPrint(allocator, "only when {s} {s}", .{
        name,
        if (negated) "does not hold" else "holds",
    });
}

/// Stated absences, and only once something else has been asked for: a list of
/// nothing but reassurances would replace the "requests nothing" state that the
/// empty page exists to show.
fn addAbsences(buckets: *Buckets) void {
    var any_grant = false;
    for (buckets) |b| {
        if (b.granted) {
            any_grant = true;
            break;
        }
    }
    if (!any_grant) return;
    for ([_]Concern{ .network, .devices, .files_system }) |concern| {
        const b = bucket(buckets, concern);
        if (b.mentioned) continue;
        b.absent = true;
        b.mentioned = true;
    }
}

fn collectRows(allocator: std.mem.Allocator, buckets: *Buckets) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |row| {
            for (row.items) |item| allocator.free(item);
            allocator.free(row.items);
        }
        rows.deinit(allocator);
    }

    for (buckets, 0..) |*b, index| {
        if (!b.mentioned) continue;
        if (b.absent) {
            try rows.append(allocator, .{
                .concern = @enumFromInt(index),
                .tier = .low,
                .state = .absent,
                .items = &.{},
            });
            continue;
        }
        try rows.append(allocator, .{
            .concern = @enumFromInt(index),
            .tier = if (b.granted) b.tier else .low,
            .state = .granted,
            .items = try b.items.toOwnedSlice(allocator),
        });
    }

    std.mem.sort(Row, rows.items, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            if (a.state != b.state) return a.state == .granted;
            if (a.tier != b.tier) return a.tier.rank() > b.tier.rank();
            return @intFromEnum(a.concern) < @intFromEnum(b.concern);
        }
    }.lessThan);
    return rows.toOwnedSlice(allocator);
}

fn fixture(entries: []const []const u8) ![]const u8 {
    const allocator = std.testing.allocator;
    var summary = try classify(allocator, entries);
    defer summary.deinit(allocator);
    return describe(allocator, summary.rows);
}

test "flatpak permission classifier groups tokens into one row per concern" {
    // The sixteen tokens a filesystem-heavy app arrives as, from the metadata
    // of com.tutanota.Tutanota on this machine.
    const described = try fixture(&.{
        "Context=shared:ipc",
        "Context=shared:network",
        "Context=sockets:fallback-x11",
        "Context=sockets:pulseaudio",
        "Context=sockets:wayland",
        "Context=devices:all",
        "Context=devices:dri",
        "Context=filesystems:xdg-music",
        "Context=filesystems:xdg-pictures",
        "Context=filesystems:xdg-public-share",
        "Context=filesystems:xdg-videos",
        "Context=filesystems:xdg-download",
        "Context=filesystems:xdg-run/keyring",
        "Context=filesystems:xdg-documents",
        "Context=filesystems:host:ro",
        "Context=filesystems:xdg-desktop",
    });
    defer std.testing.allocator.free(described);

    // Highest risk first, so the reader meets /dev and the keyring socket
    // before the music folder.
    try std.testing.expectEqualStrings(
        "Running services: xdg-run/keyring (read/write); " ++
            "Devices: every device node, graphics acceleration (DRI); " ++
            "Display server: X11, Wayland; " ++
            "System files: the whole filesystem (read-only); " ++
            "User folders: Music (read/write), Pictures (read/write), Public Share (read/write), Videos (read/write), Downloads (read/write), Documents (read/write), Desktop (read/write); " ++
            "Network access; Sound; Inter-process communication",
        described,
    );
}

test "flatpak permission classifier reads the policy groups on their own axis" {
    const allocator = std.testing.allocator;
    var summary = try classify(allocator, &.{
        "Session Bus Policy=org.freedesktop.secrets:talk",
        "Session Bus Policy=org.gtk.vfs.*:own",
        "System Bus Policy=net.reactivated.Fprint:talk",
        "Environment=TMPDIR:/var/tmp",
        // A `;` inside an [Environment] value stays inside one entry.
        "Environment=GST_PLUGIN_PATH:/app/lib/gstreamer-1.0;/app/lib/gst",
    });
    defer summary.deinit(allocator);

    // Six rows: the three concerns above plus the three absences this app did
    // not ask about. Nothing lands in `other`, which is what made the D-Bus
    // grants read as "talk / Other" once.
    try std.testing.expectEqual(@as(usize, 6), summary.rows.len);
    try std.testing.expectEqual(@as(usize, 0), summary.malformed);

    const session = summary.rows[0];
    try std.testing.expectEqual(Concern.session_bus, session.concern);
    try std.testing.expectEqual(Tier.high, session.tier); // `own` outranks `talk`
    try std.testing.expectEqualStrings("org.freedesktop.secrets (talk)", session.items[0]);
    try std.testing.expectEqualStrings("org.gtk.vfs.* (own)", session.items[1]);

    const system = summary.rows[1];
    try std.testing.expectEqual(Concern.system_bus, system.concern);
    try std.testing.expectEqual(Tier.high, system.tier);
    try std.testing.expectEqualStrings("net.reactivated.Fprint (talk)", system.items[0]);

    const environment = summary.rows[2];
    try std.testing.expectEqual(Concern.environment, environment.concern);
    try std.testing.expectEqualStrings("TMPDIR=/var/tmp", environment.items[0]);
    try std.testing.expectEqualStrings(
        "GST_PLUGIN_PATH=/app/lib/gstreamer-1.0;/app/lib/gst",
        environment.items[1],
    );

    // The absences follow the grants, in the same concern order the grants
    // would have used.
    try std.testing.expectEqual(Concern.files_system, summary.rows[3].concern);
    try std.testing.expectEqual(State.absent, summary.rows[3].state);
    try std.testing.expectEqual(Concern.devices, summary.rows[4].concern);
    try std.testing.expectEqual(Concern.network, summary.rows[5].concern);
}

test "flatpak permission classifier interprets denials and conditions" {
    const described = try fixture(&.{
        "Context=sockets:!x11",
        "Context=sockets:if:x11:!has-wayland",
        "Context=devices:!usb",
        "Context=filesystems:host-etc:create",
    });
    defer std.testing.allocator.free(described);

    // The conditional X11 grant outranks the read-mostly /etc grant, the `!usb`
    // removal is not a grant at all, and the one concern the app never mentioned
    // is stated as an absence.
    try std.testing.expectEqualStrings(
        "Display server: X11 (not granted), X11 (only when Wayland is not running); " ++
            "System files: system configuration in /etc (read/write, may create); " ++
            "Devices: USB devices (not granted); " ++
            "No network access",
        described,
    );
}

test "flatpak permission classifier rates a folder below the tree it sits in" {
    const allocator = std.testing.allocator;

    // `xdg-config` is every program's settings; one folder inside it usually is
    // the app's own, so the two must not read with the same urgency.
    var whole = try classify(allocator, &.{"Context=filesystems:xdg-config"});
    defer whole.deinit(allocator);
    try std.testing.expectEqual(Tier.high, whole.rows[0].tier);
    try std.testing.expectEqualStrings("every app's settings in ~/.config (read/write)", whole.rows[0].items[0]);

    var subpath = try classify(allocator, &.{"Context=filesystems:xdg-config/GIMP"});
    defer subpath.deinit(allocator);
    try std.testing.expectEqual(Concern.files_config, subpath.rows[0].concern);
    try std.testing.expectEqual(Tier.medium, subpath.rows[0].tier);
    // The path is the news, so it is shown as flatpak wrote it.
    try std.testing.expectEqualStrings("xdg-config/GIMP (read/write)", subpath.rows[0].items[0]);

    // `xdg-run/` has no whole-tree form, and every socket under it is named, so
    // the runtime concern keeps its tier.
    var runtime = try classify(allocator, &.{"Context=filesystems:xdg-run/keyring"});
    defer runtime.deinit(allocator);
    try std.testing.expectEqual(Concern.files_runtime, runtime.rows[0].concern);
    try std.testing.expectEqual(Tier.high, runtime.rows[0].tier);
}

test "flatpak permission classifier keeps an unread request separate from none" {
    const allocator = std.testing.allocator;

    var none = try classify(allocator, &.{});
    defer none.deinit(allocator);
    // No grants, so no absence statements either: the empty page is the answer.
    try std.testing.expectEqual(@as(usize, 0), none.rows.len);
    try std.testing.expectEqual(@as(usize, 0), none.malformed);

    var junk = try classify(allocator, &.{ "network", "shared=network", "Context=" });
    defer junk.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), junk.malformed);
    try std.testing.expectEqual(@as(usize, 0), junk.rows.len);
}

test "flatpak permission classifier keeps unknown vocabulary visible" {
    const allocator = std.testing.allocator;
    var summary = try classify(allocator, &.{
        "Context=devices:nvidia",
        "Context=shared:vsock",
        "Context=sockets:v4l2",
        "Context=filesystems:xdg-webapps",
        "Context=networks:anything",
        "Audio=never:talk",
    });
    defer summary.deinit(allocator);

    var devices: ?Row = null;
    var other: ?Row = null;
    var files: ?Row = null;
    for (summary.rows) |row| {
        switch (row.concern) {
            .devices => devices = row,
            .other => other = row,
            .files_paths => files = row,
            else => {},
        }
    }

    // A device node nobody had heard of still belongs under Devices.
    try std.testing.expectEqual(Tier.medium, devices.?.tier);
    try std.testing.expectEqualStrings("nvidia", devices.?.items[0]);

    // `shared=vsock` and `sockets=v4l2` have no single concern, so they land in
    // Other rather than vanishing the way the six invented group names did.
    try std.testing.expectEqual(@as(usize, 4), other.?.items.len);
    try std.testing.expectEqualStrings("vsock", other.?.items[0]);
    try std.testing.expectEqualStrings("v4l2", other.?.items[1]);
    try std.testing.expectEqualStrings("networks=anything", other.?.items[2]);
    try std.testing.expectEqualStrings("Audio never=talk", other.?.items[3]);

    // A filesystem keyword that is neither known nor a path: shown verbatim,
    // with the direction flatpak would apply, under a middling tier.
    try std.testing.expectEqual(Tier.medium, files.?.tier);
    try std.testing.expectEqualStrings("xdg-webapps (read/write)", files.?.items[0]);
}

/// One line for surfaces that have one cell, such as the CLI search table.
pub fn describe(allocator: std.mem.Allocator, rows: []const Row) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    for (rows, 0..) |row, index| {
        if (index > 0) try out.writer.writeAll("; ");
        if (row.state == .absent) {
            try out.writer.writeAll(row.concern.absenceLabel() orelse row.concern.label());
            continue;
        }
        try out.writer.writeAll(row.concern.label());
        if (row.items.len == 0) continue;
        try out.writer.writeAll(": ");
        for (row.items, 0..) |item, item_index| {
            if (item_index > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(item);
        }
    }
    return out.toOwnedSlice();
}
