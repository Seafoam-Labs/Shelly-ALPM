const std = @import("std");
const Zigalpm = @import("Zigalpm");
const test_support = @import("test_support.zig");
const install = @import("install.zig");
const parser = @import("../cli/parser.zig");
const output = @import("../output/config.zig");
const colors = @import("../output/colors.zig");
const format = @import("../output/format.zig");
const runtime = @import("../runtime/context.zig");
const aur_url = @import("../config/aur_url.zig");

const command_path = "shelly";
const maximum_results = 10;

pub const Source = enum {
    standard,
    aur,
};

pub const Candidate = struct {
    source: Source,
    name: []const u8,
    version: []const u8 = "",
    description: []const u8 = "",
    repository: []const u8 = "",
    popularity: f64 = 0,
    score: u16 = 0,
    is_installed: bool = false,
};

const DiscoveryResult = struct {
    candidates: []Candidate,
    standard_error: ?anyerror = null,
    aur_error: ?anyerror = null,
};

const Discoverer = struct {
    fn call(
        _: @This(),
        context: *runtime.RuntimeContext,
        query: []const u8,
        aur_base: []const u8,
    ) !DiscoveryResult {
        return discoverReal(context, query, aur_base);
    }
};

const Installer = struct {
    fn call(
        _: @This(),
        context: *runtime.RuntimeContext,
        candidate: Candidate,
        no_confirm: bool,
        aur_override: ?[]const u8,
    ) !u8 {
        return installReal(context, candidate, no_confirm, aur_override);
    }
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    if (!std.mem.eql(u8, invocation.command.path, command_path) or invocation.positionals.len == 0)
        return null;
    return try executeWith(context, invocation, Discoverer{}, Installer{});
}

fn executeWith(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    discoverer: anytype,
    installer: anytype,
) anyerror!u8 {
    if (invocation.globals.ui_mode or invocation.globals.json) {
        try context.stderr.writeAll(
            "Interactive package selection does not support --ui-mode or --json; use an explicit search command.\n",
        );
        return 1;
    }

    const joined = try std.mem.join(context.allocator, " ", invocation.positionals);
    const query = std.mem.trim(u8, joined, " \t\r\n");
    if (query.len == 0) {
        try context.stderr.writeAll("Package search query cannot be empty.\n");
        return 1;
    }

    const aur_base = try aur_url.resolveFor(context, invocation);
    const aur_override: ?[]const u8 = aur_base;

    const discovery = discoverer.call(context, query, aur_base) catch |err| {
        const message = try Zigalpm.user_errors.format(context.allocator, err, .{ .operation = "the package search" });
        defer context.allocator.free(message);
        try context.stderr.print("{s}\n", .{message});
        return 1;
    };
    const partial_results = if (discovery.candidates.len > 0) " Results from the other package sources are still available." else "";
    if (discovery.standard_error) |err|
        try context.stderr.print("warning: Could not refresh standard package information.{s}\n\nTechnical details: {t}\n", .{ partial_results, err });
    if (discovery.aur_error) |err|
        try context.stderr.print("warning: Could not refresh AUR package information.{s}\n\nTechnical details: {t}\n", .{ partial_results, err });

    const candidates = try prepareCandidates(context.allocator, discovery.candidates, query);
    if (candidates.len == 0) {
        try context.stderr.print("No standard or AUR packages matched '{s}'.\n", .{query});
        return 1;
    }

    const selected_index: ?usize = if (invocation.globals.no_confirm)
        candidates.len - 1
    else blk: {
        if (!context.stdin_is_tty or !context.stdout_is_tty or context.stdin == null) {
            try context.stderr.writeAll(
                "Interactive package selection requires a terminal; use --no-confirm to select the closest match.\n",
            );
            return 1;
        }
        break :blk try promptSelection(context, query, candidates);
    };
    const index = selected_index orelse {
        try context.stdout.writeAll("Installation cancelled.\n");
        return 0;
    };
    return installer.call(context, candidates[index], invocation.globals.no_confirm, aur_override) catch |err| {
        try context.stderr.print("Unable to start installation: {t}\n", .{err});
        return 1;
    };
}

fn discoverReal(
    context: *runtime.RuntimeContext,
    query: []const u8,
    aur_base: []const u8,
) !DiscoveryResult {
    var candidates: std.ArrayList(Candidate) = .empty;
    const standard_error: ?anyerror = error_value: {
        discoverStandard(context, query, &candidates) catch |err| break :error_value err;
        break :error_value null;
    };
    const aur_error: ?anyerror = error_value: {
        discoverAur(context, query, &candidates, aur_base) catch |err| break :error_value err;
        break :error_value null;
    };
    return .{
        .candidates = try candidates.toOwnedSlice(context.allocator),
        .standard_error = standard_error,
        .aur_error = aur_error,
    };
}

fn discoverStandard(
    context: *runtime.RuntimeContext,
    query: []const u8,
    candidates: *std.ArrayList(Candidate),
) !void {
    const manager = try Zigalpm.AlpmManager.init(
        context.allocator,
        context.environ,
        .{ .use_root = false },
    );
    defer manager.deinit();
    const packages = try manager.get_available_packages();
    defer Zigalpm.alpm.OwnedPackage.deinitSlice(context.allocator, packages);
    for (packages) |package| {
        const name = package.name() orelse continue;
        if (ignoredStandardPackage(manager, name)) continue;
        const description = package.description() orelse "";
        if (matchScore(name, description, query) == 0) continue;
        try appendUnique(context.allocator, candidates, .{
            .source = .standard,
            .name = try context.allocator.dupe(u8, name),
            .version = try context.allocator.dupe(u8, package.version() orelse ""),
            .description = try context.allocator.dupe(u8, description),
            .repository = try context.allocator.dupe(u8, package.repository() orelse ""),
            .is_installed = manager.is_package_installed(name),
        });
    }
}

fn discoverAur(
    context: *runtime.RuntimeContext,
    query: []const u8,
    candidates: *std.ArrayList(Candidate),
    aur_base: []const u8,
) !void {
    if (query.len < 2) return;
    const manager = try Zigalpm.AurManager.init(context.allocator, context.environ, .{
        .aur_git_base_url = aur_base,
    });
    defer manager.deinit();

    const packages = try manager.searchPackages(query);
    defer Zigalpm.aur.models.Package.deinitSlice(context.allocator, packages);
    try appendAurPackages(context.allocator, candidates, packages, query, manager.alpm);
    if (packages.len != 0) return;

    const suggestions = manager.aur_client.suggest(query) catch return;
    defer Zigalpm.aur.rpc.deinitStrings(context.allocator, suggestions);
    if (suggestions.len == 0) return;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(context.allocator);
    for (suggestions) |suggestion| try names.append(context.allocator, suggestion);
    var response = manager.aur_client.getInfo(names.items) catch return;
    defer response.deinit(context.allocator);
    try appendAurPackages(context.allocator, candidates, response.results, query, manager.alpm);
}

fn appendAurPackages(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    packages: []const Zigalpm.aur.models.Package,
    query: []const u8,
    manager: *Zigalpm.AlpmManager,
) !void {
    for (packages) |package| {
        const description = package.description orelse "";
        if (matchScore(package.name, description, query) == 0) continue;
        const name_z = try allocator.dupeZ(u8, package.name);
        defer allocator.free(name_z);
        try appendUnique(allocator, candidates, .{
            .source = .aur,
            .name = try allocator.dupe(u8, package.name),
            .version = try allocator.dupe(u8, package.version),
            .description = try allocator.dupe(u8, description),
            .popularity = package.popularity,
            .is_installed = manager.is_package_installed(name_z),
        });
    }
}

fn appendUnique(
    allocator: std.mem.Allocator,
    candidates: *std.ArrayList(Candidate),
    candidate: Candidate,
) !void {
    for (candidates.items) |existing| {
        if (existing.source == candidate.source and std.ascii.eqlIgnoreCase(existing.name, candidate.name))
            return;
    }
    try candidates.append(allocator, candidate);
}

fn ignoredStandardPackage(manager: *Zigalpm.AlpmManager, name: []const u8) bool {
    for (manager.config.ignore_package.items) |ignored| {
        if (std.mem.eql(u8, ignored, name)) return true;
    }
    return false;
}

fn prepareCandidates(
    allocator: std.mem.Allocator,
    discovered: []const Candidate,
    query: []const u8,
) ![]Candidate {
    var scored: std.ArrayList(Candidate) = .empty;
    defer scored.deinit(allocator);
    for (discovered) |candidate_value| {
        var candidate = candidate_value;
        candidate.score = matchScore(candidate.name, candidate.description, query);
        if (candidate.score > 0) try scored.append(allocator, candidate);
    }
    std.mem.sort(Candidate, scored.items, {}, betterCandidate);

    var selected: std.ArrayList(Candidate) = .empty;
    for (scored.items) |candidate| {
        var duplicate = false;
        for (selected.items) |existing| {
            if (existing.source == candidate.source and std.ascii.eqlIgnoreCase(existing.name, candidate.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        try selected.append(allocator, candidate);
        if (selected.items.len == maximum_results) break;
    }
    std.mem.reverse(Candidate, selected.items);
    return selected.toOwnedSlice(allocator);
}

fn betterCandidate(_: void, left: Candidate, right: Candidate) bool {
    if (left.score != right.score) return left.score > right.score;
    if (left.source != right.source) return left.source == .standard;
    if (left.popularity != right.popularity) return left.popularity > right.popularity;
    return orderIgnoreCase(left.name, right.name) == .lt;
}

fn matchScore(name: []const u8, description: []const u8, query_value: []const u8) u16 {
    const query = std.mem.trim(u8, query_value, " \t\r\n");
    if (query.len == 0) return 0;
    if (std.ascii.eqlIgnoreCase(name, query)) return 10_000;
    if (startsWithIgnoreCase(name, query)) return 8_000;
    if (containsWordIgnoreCase(name, query)) return 6_000;
    if (containsIgnoreCase(name, query)) return 4_000;
    if (startsWithIgnoreCase(description, query)) return 2_000;
    if (containsWordIgnoreCase(description, query)) return 1_500;
    if (containsIgnoreCase(description, query)) return 1_000;
    const similarity = editSimilarity(name, query);
    return if (similarity >= 450) similarity else 0;
}

fn editSimilarity(left_value: []const u8, right_value: []const u8) u16 {
    const maximum_length = 256;
    const left = left_value[0..@min(left_value.len, maximum_length)];
    const right = right_value[0..@min(right_value.len, maximum_length)];
    const longest = @max(left.len, right.len);
    if (longest == 0) return 999;
    if (left.len == 0 or right.len == 0) return 0;

    var rows: [3][maximum_length + 1]u16 = undefined;
    for (0..right.len + 1) |index| rows[0][index] = @intCast(index);
    for (1..left.len + 1) |left_index| {
        const current = &rows[left_index % 3];
        const previous = &rows[(left_index - 1) % 3];
        current[0] = @intCast(left_index);
        for (1..right.len + 1) |right_index| {
            const substitution: u16 = if (normalizedByte(left[left_index - 1]) ==
                normalizedByte(right[right_index - 1])) 0 else 1;
            current[right_index] = @min(
                @min(previous[right_index] + 1, current[right_index - 1] + 1),
                previous[right_index - 1] + substitution,
            );
            if (left_index > 1 and right_index > 1 and
                normalizedByte(left[left_index - 1]) == normalizedByte(right[right_index - 2]) and
                normalizedByte(left[left_index - 2]) == normalizedByte(right[right_index - 1]))
            {
                const previous_previous = &rows[(left_index - 2) % 3];
                current[right_index] = @min(current[right_index], previous_previous[right_index - 2] + 1);
            }
        }
    }
    const distance = rows[left.len % 3][right.len];
    const bounded_distance = @min(@as(usize, distance), longest);
    return @intCast((longest - bounded_distance) * 999 / longest);
}

fn normalizedByte(value: u8) u8 {
    return switch (value) {
        '-', '_', '.', ' ' => ' ',
        else => std.ascii.toLower(value),
    };
}

fn promptSelection(
    context: *runtime.RuntimeContext,
    query: []const u8,
    candidates: []const Candidate,
) !?usize {
    try context.stdout.print("Packages matching '{s}':\n", .{query});
    const use_color = output.supportsAnsi(context);
    for (candidates, 0..) |candidate, index| {
        const number = candidates.len - index;
        const most_likely = index + 1 == candidates.len;
        if (most_likely and use_color) try context.stdout.writeAll(colors.colorCode(.highlight));
        try context.stdout.print("{d}) {s} — ", .{ number, candidate.name });
        switch (candidate.source) {
            .standard => try context.stdout.writeAll("standard"),
            .aur => try context.stdout.writeAll("AUR"),
        }
        if (candidate.version.len > 0) try context.stdout.print(" {s}", .{candidate.version});
        if (candidate.description.len > 0)
            try context.stdout.print(" — {s}", .{truncate(candidate.description, 80)});
        if (most_likely) try context.stdout.writeAll(" [Most likely match]");
        if (candidate.is_installed) try context.stdout.writeAll(" [Installed]");
        if (most_likely and use_color) try context.stdout.writeAll(colors.reset);
        try context.stdout.writeByte('\n');
    }
    try context.stdout.writeAll("0) Cancel\n");
    while (true) {
        try context.stdout.writeAll("Select [1]: ");
        try context.stdout.flush();
        const input = (try context.stdin.?.takeDelimiter('\n')) orelse return candidates.len - 1;
        const answer = std.mem.trim(u8, input, " \t\r\n");
        if (answer.len == 0) return candidates.len - 1;
        const number = std.fmt.parseInt(usize, answer, 10) catch {
            try context.stdout.print("Please enter a number between 0 and {d}.\n", .{candidates.len});
            continue;
        };
        if (number == 0) return null;
        if (number <= candidates.len) return candidates.len - number;
        try context.stdout.print("Please enter a number between 0 and {d}.\n", .{candidates.len});
    }
}

fn installReal(
    context: *runtime.RuntimeContext,
    candidate: Candidate,
    no_confirm: bool,
    aur_override: ?[]const u8,
) !u8 {
    const target = if (candidate.source == .standard and candidate.repository.len > 0)
        try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ candidate.repository, candidate.name })
    else
        candidate.name;
    return install.call(
        context,
        if (candidate.source == .standard) .standard else .aur,
        &.{target},
        .{ .no_confirm = no_confirm, .aur_url = aur_override },
    );
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    for (0..value.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn containsWordIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > value.len) return false;
    for (0..value.len - needle.len + 1) |index| {
        if (!std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) continue;
        const left_ok = index == 0 or !std.ascii.isAlphanumeric(value[index - 1]);
        const right = index + needle.len;
        const right_ok = right == value.len or !std.ascii.isAlphanumeric(value[right]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

fn orderIgnoreCase(left: []const u8, right: []const u8) std.math.Order {
    const count = @min(left.len, right.len);
    for (left[0..count], right[0..count]) |left_byte, right_byte| {
        const left_lower = std.ascii.toLower(left_byte);
        const right_lower = std.ascii.toLower(right_byte);
        if (left_lower < right_lower) return .lt;
        if (left_lower > right_lower) return .gt;
    }
    return std.math.order(left.len, right.len);
}

fn truncate(value: []const u8, maximum: usize) []const u8 {
    return format.truncate(value, maximum);
}

test "candidate preparation puts the closest standard match last" {
    const candidates = [_]Candidate{
        .{ .source = .aur, .name = "firefox-esr", .version = "1", .popularity = 20 },
        .{ .source = .standard, .name = "firefox", .repository = "extra", .version = "2" },
        .{ .source = .standard, .name = "firefox-developer-edition", .repository = "extra", .version = "3" },
    };
    const prepared = try prepareCandidates(std.testing.allocator, &candidates, "firefox");
    defer std.testing.allocator.free(prepared);
    try std.testing.expectEqual(@as(usize, 3), prepared.len);
    try std.testing.expectEqualStrings("firefox-esr", prepared[0].name);
    try std.testing.expectEqualStrings("firefox", prepared[2].name);
    try std.testing.expectEqual(@as(u16, 10_000), prepared[2].score);
}

test "reverse-numbered selection defaults one to the final closest match" {
    var stdin = std.Io.Reader.fixed("\n");
    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    var context: runtime.RuntimeContext = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stdin = &stdin,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    };
    const candidates = [_]Candidate{
        .{ .source = .aur, .name = "firefox-esr" },
        .{ .source = .standard, .name = "firefox-developer-edition", .repository = "extra" },
        .{ .source = .standard, .name = "firefox", .repository = "extra" },
    };
    try std.testing.expectEqual(@as(?usize, 2), try promptSelection(&context, "firefox", &candidates));
    const rendered = stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "3) firefox-esr") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2) firefox-developer-edition") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "1) firefox — standard") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "standard/extra") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[Most likely match]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[32m1) firefox") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[Most likely match]\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Select [1]:") != null);

    var numbered_input = std.Io.Reader.fixed("3\n");
    context.stdin = &numbered_input;
    try std.testing.expectEqual(@as(?usize, 0), try promptSelection(&context, "firefox", &candidates));

    var cancel_input = std.Io.Reader.fixed("0\n");
    context.stdin = &cancel_input;
    try std.testing.expectEqual(@as(?usize, null), try promptSelection(&context, "firefox", &candidates));
}

test "fuzzy score handles insertion and transposition typos" {
    try std.testing.expect(matchScore("firefox", "", "fiirefox") >= 450);
    try std.testing.expect(matchScore("firefox", "", "friefox") >= 450);
    try std.testing.expectEqual(@as(u16, 0), matchScore("linux", "kernel", "firefox"));
}

test "no-confirm installs the final closest candidate and preserves partial results" {
    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();
    const manifest = try @import("../cli/spec.zig").Manifest.load(tc.arena.allocator());
    const outcome = try parser.parse(
        tc.arena.allocator(),
        &manifest,
        &.{ "demo", "--no-confirm" },
    );
    try std.testing.expect(outcome == .dispatch);

    const Capture = struct {
        installed_name: ?[]const u8 = null,
        source: ?Source = null,
        no_confirm: bool = false,
        aur_override: ?[]const u8 = null,

        fn call(
            self: *@This(),
            _: *runtime.RuntimeContext,
            candidate: Candidate,
            no_confirm: bool,
            aur_override: ?[]const u8,
        ) !u8 {
            self.installed_name = candidate.name;
            self.source = candidate.source;
            self.no_confirm = no_confirm;
            self.aur_override = aur_override;
            return 23;
        }
    };
    var capture: Capture = .{};
    const FakeDiscoverer = struct {
        fn call(
            _: @This(),
            _: *runtime.RuntimeContext,
            query: []const u8,
            _: []const u8,
        ) !DiscoveryResult {
            try std.testing.expectEqualStrings("demo", query);
            return .{
                .candidates = @constCast(&[_]Candidate{
                    .{ .source = .aur, .name = "demo-git", .version = "1" },
                    .{ .source = .standard, .name = "demo", .repository = "extra", .version = "2" },
                }),
                .aur_error = error.Timeout,
            };
        }
    };

    try std.testing.expectEqual(
        @as(u8, 23),
        try executeWith(&tc.context, &outcome.dispatch, FakeDiscoverer{}, &capture),
    );
    try std.testing.expectEqualStrings("demo", capture.installed_name.?);
    try std.testing.expectEqual(Source.standard, capture.source.?);
    try std.testing.expect(capture.no_confirm);
    try std.testing.expectEqualStrings(aur_url.default_base, capture.aur_override.?);
    try std.testing.expect(std.mem.indexOf(u8, tc.stderr.writer.buffered(), "warning: Could not refresh AUR package information") != null);
}
