//! Offline checks of the reference inventory. Passing is not a behavioral parity claim.
const std = @import("std");
const reference = @import("reference/assets.zig");

const ledger = @embedFile("compatibility-ledger.tsv");
const evidence = @embedFile("compatibility-evidence.tsv");
const upstream = @embedFile("reference/upstream-alpm.h");
const downstream = @embedFile("reference/downstream-alpm.h");
const lists = @embedFile("reference/alpm_list.h");

const Row = struct {
    symbol: []const u8,
    kind: []const u8,
    origin: []const u8,
    feature: []const u8,
    equivalent: []const u8,
    status: []const u8,
    evidence_id: []const u8,
    fixture: []const u8,
    source: []const u8,
};

fn readRows() !std.ArrayList(Row) {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(std.testing.allocator);
    var lines = std.mem.tokenizeScalar(u8, ledger, '\n');
    try std.testing.expectEqualStrings(
        "symbol\tkind\torigin\tfeature\trlpm_equivalent\tstatus\tevidence\tplanned_fixture\treference",
        lines.next().?,
    );
    while (lines.next()) |line| {
        var columns = std.mem.splitScalar(u8, line, '\t');
        var row: Row = undefined;
        inline for (std.meta.fields(Row)) |field| {
            @field(row, field.name) = columns.next() orelse return error.MissingColumn;
            try std.testing.expect(@field(row, field.name).len > 0);
        }
        try std.testing.expect(columns.next() == null);
        try rows.append(std.testing.allocator, row);
    }
    return rows;
}

// The pinned headers contain declarations, macros, comments and includes. Scan
// identifiers outside comments/strings/includes so prose cannot invent an API.
fn collectSymbols(source: []const u8, symbols: *std.StringHashMap(void)) !void {
    var pos: usize = 0;
    while (pos < source.len) {
        const rest = source[pos..];
        if (std.mem.startsWith(u8, rest, "/*")) {
            pos += (std.mem.indexOf(u8, rest[2..], "*/") orelse return error.UnclosedComment) + 4;
        } else if (std.mem.startsWith(u8, rest, "//") or std.mem.startsWith(u8, rest, "#include")) {
            pos += std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        } else if (source[pos] == '"' or source[pos] == '\'') {
            const quote = source[pos];
            pos += 1;
            while (pos < source.len and source[pos] != quote) {
                if (source[pos] == '\\') pos += 1;
                pos += 1;
            }
            if (pos < source.len) pos += 1;
        } else if (std.ascii.isAlphabetic(source[pos]) or source[pos] == '_') {
            const start = pos;
            pos += 1;
            while (pos < source.len and (std.ascii.isAlphanumeric(source[pos]) or source[pos] == '_')) : (pos += 1) {}
            const name = source[start..pos];
            if (std.mem.eql(u8, name, "ALPM_H") or std.mem.eql(u8, name, "ALPM_LIST_H")) continue;
            if (std.mem.startsWith(u8, name, "alpm_") or std.mem.startsWith(u8, name, "ALPM_") or
                std.mem.eql(u8, name, "FREELIST"))
            {
                try symbols.put(name, {});
            }
        } else {
            pos += 1;
        }
    }
}

fn oneOf(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |item|
        if (std.mem.eql(u8, value, item)) return true;
    return false;
}

test "reference artifacts match their pinned SHA-256 and build provenance" {
    const Manifest = struct {
        schema: u32,
        package: struct {
            pkgbuild_sha256: []const u8,
        },
        library: struct {
            version: []const u8,
            capability_mask: u32,
        },
        assets: []const struct {
            path: []const u8,
            sha256: []const u8,
        },
    };
    const parsed = try std.json.parseFromSlice(
        Manifest,
        std.testing.allocator,
        @embedFile("reference/manifest.json"),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(1, parsed.value.schema);
    try std.testing.expectEqualStrings("16.0.1", parsed.value.library.version);
    try std.testing.expectEqual(7, parsed.value.library.capability_mask);
    try std.testing.expectEqual(reference.files.len, parsed.value.assets.len);
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (parsed.value.assets) |asset| {
        try std.testing.expect(!(try seen.getOrPut(asset.path)).found_existing);
        var found = false;
        for (reference.files) |file| {
            if (!std.mem.eql(u8, file.path, asset.path)) continue;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(file.bytes, &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            try std.testing.expectEqualStrings(asset.sha256, &hex);
            found = true;
            if (std.mem.eql(u8, asset.path, "packaging/PKGBUILD")) {
                try std.testing.expectEqualStrings(parsed.value.package.pkgbuild_sha256, &hex);
                try std.testing.expect(
                    std.mem.indexOf(u8, @embedFile("reference/packaging/.BUILDINFO"), &hex) != null,
                );
            }
        }
        try std.testing.expect(found);
    }
}

test "ledger accounts for every pinned public symbol without duplicate or invented APIs" {
    var rows = try readRows();
    defer rows.deinit(std.testing.allocator);
    var required = std.StringHashMap(void).init(std.testing.allocator);
    defer required.deinit();
    var core = std.StringHashMap(void).init(std.testing.allocator);
    defer core.deinit();
    var containers = std.StringHashMap(void).init(std.testing.allocator);
    defer containers.deinit();
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    try collectSymbols(upstream, &core);
    try collectSymbols(lists, &core);
    try collectSymbols(lists, &containers);
    try collectSymbols(downstream, &required);
    try collectSymbols(lists, &required);
    // Fixed counts make reference updates explicit and reviewable.
    try std.testing.expectEqual(493, required.count());
    var flags: usize = 0;
    var extensions: usize = 0;
    for (rows.items) |row| {
        try std.testing.expect(!(try seen.getOrPut(row.symbol)).found_existing);
        try std.testing.expect(oneOf(row.origin, &.{ "upstream", "cachyos" }));
        try std.testing.expect(oneOf(row.kind, &.{ "function", "constant", "type", "macro", "behavior" }));
        try std.testing.expect(
            oneOf(
                row.feature,
                &.{
                    "owner",
                    "metadata",
                    "database",
                    "verification",
                    "resolver",
                    "transaction",
                    "download",
                    "preflight",
                    "actions",
                    "executor",
                    "native-backend",
                },
            ),
        );
        try std.testing.expect(
            oneOf(
                row.status,
                &.{ "missing", "partial", "representation_only", "verified" },
            ),
        );
        try std.testing.expect(std.mem.startsWith(u8, row.fixture, row.feature));
        try std.testing.expect(std.mem.endsWith(u8, row.fixture, row.symbol));
        if (std.mem.eql(u8, row.kind, "behavior")) {
            try std.testing.expect(std.mem.startsWith(u8, row.symbol, "behavior."));
        } else {
            try std.testing.expect(required.contains(row.symbol));
            const expected_origin: []const u8 = if (core.contains(row.symbol)) "upstream" else "cachyos";
            try std.testing.expectEqualStrings(expected_origin, row.origin);
            if (!core.contains(row.symbol)) extensions += 1;
        }
        if (std.mem.eql(u8, row.status, "representation_only")) {
            try std.testing.expect(containers.contains(row.symbol));
        }
        if (std.mem.startsWith(u8, row.symbol, "ALPM_TRANS_FLAG_")) flags += 1;
    }
    var names = required.keyIterator();
    while (names.next()) |name|
        try std.testing.expect(seen.contains(name.*));
    try std.testing.expectEqual(16, flags);
    try std.testing.expectEqual(4, extensions);
}

test "ledger assigns CachyOS behavior behind shared APIs to the responsible feature" {
    var rows = try readRows();
    defer rows.deinit(std.testing.allocator);
    const required = .{
        .{ "cachyos-sqlite-sync", "database" },
        .{ "cachyos-physical-architectures", "owner" },
        .{ "cachyos-architecture-auto", "native-backend" },
        .{ "cachyos-installed-db-read", "metadata" },
        .{ "cachyos-installed-db-write", "executor" },
        .{ "cachyos-network-isolation", "actions" },
        .{ "cachyos-hook-network-access", "actions" },
        .{ "cachyos-disable-sandbox", "actions" },
        .{ "cachyos-ldconfig-network", "actions" },
        .{ "cachyos-curl-child-cleanup", "actions" },
    };
    inline for (required) |item| {
        var found = false;
        for (rows.items) |row| {
            if (!std.mem.eql(u8, row.symbol, "behavior." ++ item[0])) continue;
            try std.testing.expectEqualStrings("cachyos", row.origin);
            try std.testing.expectEqualStrings(item[1], row.feature);
            try std.testing.expect(!std.mem.eql(u8, row.status, "representation_only"));
            found = true;
        }
        try std.testing.expect(found);
    }
}

test "coverage claims distinguish unit evidence from independent reference expectations" {
    var rows = try readRows();
    defer rows.deinit(std.testing.allocator);
    var evidence_kinds = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer evidence_kinds.deinit();
    var lines = std.mem.tokenizeScalar(u8, evidence, '\n');
    try std.testing.expectEqualStrings("id\tkind\tsource\tscope", lines.next().?);
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = fields.next() orelse return error.MissingColumn;
        const kind = fields.next() orelse return error.MissingColumn;
        try std.testing.expect(oneOf(kind, &.{ "unit", "integration", "reference-fixture" }));
        const entry = try evidence_kinds.getOrPut(id);
        try std.testing.expect(!entry.found_existing);
        entry.value_ptr.* = kind;
        try std.testing.expect((fields.next() orelse return error.MissingColumn).len > 0);
        try std.testing.expect((fields.next() orelse return error.MissingColumn).len > 0);
        try std.testing.expect(fields.next() == null);
    }
    for (rows.items) |row| {
        const kind = evidence_kinds.get(row.evidence_id);
        if (!std.mem.eql(u8, row.evidence_id, "-")) try std.testing.expect(kind != null);
        if (std.mem.eql(u8, row.status, "verified")) {
            try std.testing.expectEqualStrings(
                "reference-fixture",
                kind orelse
                    return error.MissingParityEvidence,
            );
        }
    }
}
