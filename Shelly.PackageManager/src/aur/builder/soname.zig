//! Soname expansion for bare `*.so` provides/depends entries, reproducing
//! makepkg's libprovides/libdepends packaging step. Bare soname entries gain
//! `=<version>-<32|64>` derived from the packaged ELF payload, so versioned
//! soname dependencies such as `libfoo.so=1-64` can be satisfied by the
//! libraries a package actually ships.
//! After package() and tidy, the payload is inspected natively: provides
//! entries are versioned from each library's DT_SONAME, and depends entries
//! from the DT_NEEDED requirements of packaged user-executable files.
//! Unresolvable entries stay bare and produce makepkg's warnings; the build
//! never fails because of them.

const std = @import("std");
const steps = @import("steps.zig");
const PackageBuilder = @import("builder.zig").PackageBuilder;

/// Bounds for untrusted ELF metadata. Files exceeding them are treated as
/// opaque, exactly like a failed readelf invocation in makepkg.
const max_program_headers = 4096;
const max_load_segments = 64;
const max_table_bytes = 1 << 20;

/// ELF dynamic-section facts needed for soname versioning. Strings are owned
/// copies; `needed` preserves DT_NEEDED order.
pub const ElfDynamic = struct {
    allocator: std.mem.Allocator,
    /// ELF class in bits: 32 or 64.
    class: u8,
    /// ELF header e_type; 3 is ET_DYN (shared object).
    elf_type: u16,
    soname: ?[]u8 = null,
    needed: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *ElfDynamic) void {
        if (self.soname) |name| self.allocator.free(name);
        for (self.needed.items) |name| self.allocator.free(name);
        self.needed.deinit(self.allocator);
    }

    pub fn isShared(self: ElfDynamic) bool {
        return self.elf_type == 3;
    }
};

/// Reads just the ELF header, program headers, dynamic table, and dynamic
/// string table with positional reads; large payloads are never slurped.
/// Returns null for non-ELF or malformed files (makepkg's readelf would fail
/// the same way); only allocation errors propagate. Symlinked paths must be
/// filtered out by the caller before opening.
pub fn readElfDynamic(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
) std.mem.Allocator.Error!?ElfDynamic {
    var file = dir.openFile(io, sub_path, .{}) catch return null;
    defer file.close(io);

    var header: [64]u8 = undefined;
    const header_len = file.readPositionalAll(io, &header, 0) catch return null;
    if (header_len < 52 or !std.mem.eql(u8, header[0..4], "\x7fELF")) return null;
    const class = header[4];
    const encoding = header[5];
    if ((class != 1 and class != 2) or (encoding != 1 and encoding != 2)) return null;
    const endian: std.builtin.Endian = if (encoding == 1) .little else .big;
    const wide = class == 2;
    if (wide and header_len < 64) return null;

    var info: ElfDynamic = .{
        .allocator = allocator,
        .class = class * 32,
        .elf_type = std.mem.readInt(u16, header[16..18], endian),
    };
    errdefer info.deinit();

    const phoff = if (wide) std.mem.readInt(u64, header[32..40], endian) else std.mem.readInt(u32, header[28..32], endian);
    const phentsize = if (wide) std.mem.readInt(u16, header[54..56], endian) else std.mem.readInt(u16, header[42..44], endian);
    const phnum = if (wide) std.mem.readInt(u16, header[56..58], endian) else std.mem.readInt(u16, header[44..46], endian);
    // PN_XNUM (0xffff) stores the real count in section header zero; such
    // files are rare and treated as opaque here.
    if (phnum == 0 or phnum > max_program_headers or phentsize < @as(u16, if (wide) 56 else 32)) return info;
    const table_len = @as(u64, phnum) * phentsize;
    if (table_len > max_table_bytes) return info;
    const table = try allocator.alloc(u8, @intCast(table_len));
    defer allocator.free(table);
    if ((file.readPositionalAll(io, table, phoff) catch return null) < table.len) return info;

    const Load = struct { offset: u64, vaddr: u64, filesz: u64 };
    var loads: [max_load_segments]Load = undefined;
    var load_count: usize = 0;
    var dynamic_offset: ?u64 = null;
    var dynamic_size: u64 = 0;
    for (0..phnum) |i| {
        const ph = table[i * phentsize ..][0..phentsize];
        const p_type = std.mem.readInt(u32, ph[0..4], endian);
        const p_offset = if (wide) std.mem.readInt(u64, ph[8..16], endian) else std.mem.readInt(u32, ph[4..8], endian);
        const p_vaddr = if (wide) std.mem.readInt(u64, ph[16..24], endian) else std.mem.readInt(u32, ph[8..12], endian);
        const p_filesz = if (wide) std.mem.readInt(u64, ph[32..40], endian) else std.mem.readInt(u32, ph[16..20], endian);
        if (p_type == 1) {
            if (load_count < loads.len) {
                loads[load_count] = .{ .offset = p_offset, .vaddr = p_vaddr, .filesz = p_filesz };
                load_count += 1;
            }
        } else if (p_type == 2 and dynamic_offset == null) {
            dynamic_offset = p_offset;
            dynamic_size = p_filesz;
        }
    }
    const dyn_offset = dynamic_offset orelse return info;
    if (dynamic_size == 0 or dynamic_size > max_table_bytes) return info;
    const dynamic = try allocator.alloc(u8, @intCast(dynamic_size));
    defer allocator.free(dynamic);
    const dynamic_len = file.readPositionalAll(io, dynamic, dyn_offset) catch return null;

    const entry_size: usize = if (wide) 16 else 8;
    var strtab_vaddr: u64 = 0;
    var strtab_size: u64 = 0;
    var soname_offset: ?u64 = null;
    var needed_offsets: std.ArrayListUnmanaged(u64) = .empty;
    defer needed_offsets.deinit(allocator);
    var pos: usize = 0;
    while (pos + entry_size <= dynamic_len) : (pos += entry_size) {
        const tag = if (wide) std.mem.readInt(u64, dynamic[pos..][0..8], endian) else std.mem.readInt(u32, dynamic[pos..][0..4], endian);
        const val = if (wide) std.mem.readInt(u64, dynamic[pos + 8 ..][0..8], endian) else std.mem.readInt(u32, dynamic[pos + 4 ..][0..4], endian);
        switch (tag) {
            0 => break, // DT_NULL
            1 => try needed_offsets.append(allocator, val), // DT_NEEDED
            5 => strtab_vaddr = val, // DT_STRTAB
            10 => strtab_size = val, // DT_STRSZ
            14 => soname_offset = val, // DT_SONAME
            else => {},
        }
    }
    if (strtab_vaddr == 0) return info;

    // DT_STRTAB is a virtual address; translate it through PT_LOAD segments.
    var strtab_offset: ?u64 = null;
    var strtab_avail: u64 = 0;
    for (loads[0..load_count]) |load| {
        if (strtab_vaddr >= load.vaddr and strtab_vaddr - load.vaddr < load.filesz) {
            strtab_offset = load.offset + (strtab_vaddr - load.vaddr);
            strtab_avail = load.filesz - (strtab_vaddr - load.vaddr);
            break;
        }
    }
    const str_offset = strtab_offset orelse return info;
    var want = if (strtab_size != 0) @min(strtab_size, strtab_avail) else strtab_avail;
    want = @min(want, max_table_bytes);
    if (want == 0) return info;
    const strtab = try allocator.alloc(u8, @intCast(want));
    defer allocator.free(strtab);
    const strtab_len = file.readPositionalAll(io, strtab, str_offset) catch return null;
    const strings = strtab[0..strtab_len];

    if (soname_offset) |offset| {
        if (stringAt(strings, offset)) |name| info.soname = try allocator.dupe(u8, name);
    }
    for (needed_offsets.items) |offset| {
        const name = stringAt(strings, offset) orelse continue;
        const copy = try allocator.dupe(u8, name);
        errdefer allocator.free(copy);
        try info.needed.append(allocator, copy);
    }
    return info;
}

fn stringAt(strings: []const u8, offset: u64) ?[]const u8 {
    if (offset >= strings.len) return null;
    const rest = strings[@intCast(offset)..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    return rest[0..end];
}

/// makepkg derives the version with `${soname##*\.so\.}`: everything after the
/// last `.so.` separator; a name without the separator keeps its full text.
fn versionSuffix(name: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, name, ".so.")) |index| return name[index + 4 ..];
    return name;
}

/// makepkg derives the dependency key with `${needed%.so?(+(.+([0-9])))}.so`:
/// the name through the last `.so` whose remainder is empty or dot-separated
/// digit groups. Names without such a suffix cannot match a bare `*.so`
/// dependency and are skipped.
fn sonameBase(name: []const u8) ?[]const u8 {
    var end = name.len;
    while (std.mem.lastIndexOf(u8, name[0..end], ".so")) |index| {
        const candidate_end = index + 3;
        if (isVersionSuffix(name[candidate_end..])) return name[0..candidate_end];
        end = index;
    }
    return null;
}

fn isVersionSuffix(rest: []const u8) bool {
    if (rest.len == 0) return true;
    if (rest[0] != '.') return false;
    var groups = std.mem.splitScalar(u8, rest[1..], '.');
    while (groups.next()) |group| {
        if (group.len == 0) return false;
        for (group) |character| {
            if (!std.ascii.isDigit(character)) return false;
        }
    }
    return true;
}

/// Only unprefixed, unversioned `*.so` entries are expanded. Entries carrying
/// `=version` already satisfy soname dependencies, and `prefix:name` entries
/// belong to makepkg's newer opt-in autodeps mechanism.
fn isBareSoname(entry: []const u8) bool {
    return std.mem.endsWith(u8, entry, ".so") and
        std.mem.indexOfScalar(u8, entry, '=') == null and
        std.mem.indexOfScalar(u8, entry, ':') == null;
}

fn pathLessThan(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn appendDupe(list: *std.ArrayListUnmanaged([]const u8), allocator: std.mem.Allocator, text: []const u8) !void {
    const copy = try allocator.dupe(u8, text);
    errdefer allocator.free(copy);
    try list.append(allocator, copy);
}

/// Releases an expansion result returned by `expandProvides`/`expandDepends`.
pub fn freeEntries(allocator: std.mem.Allocator, entries: [][]const u8) void {
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
}

fn warn(self: *PackageBuilder, package_name: []const u8, comptime format: []const u8, args: anytype) void {
    const message = std.fmt.allocPrint(self.allocator, format, args) catch return;
    defer self.allocator.free(message);
    if (self.active_operation) |operation| {
        var context = steps.StepStreamContext{
            .operation = operation,
            .package_name = package_name,
            .log = self.active_log,
        };
        steps.forwardStepLine(&context, .stderr, message);
    } else if (self.active_log) |log| {
        log.writeStream(.stderr, message);
    }
    if (self.active_log) |log| log.ensureHealthy() catch {};
}

/// Versions bare `*.so` provides from the packaged libraries, as makepkg's
/// find_libprovides does: regular files (no symlinks) whose basename starts
/// with the entry, each shared object contributing `entry=<soname version>-
/// <class>`. Returns null when nothing needs expansion, so the caller keeps
/// the original slice; otherwise every returned entry is allocator-owned.
/// Identical versioned entries are deduplicated.
pub fn expandProvides(
    self: *PackageBuilder,
    package_name: []const u8,
    pkgdir: std.Io.Dir,
    provides: ?[][]const u8,
) !?[][]const u8 {
    const entries = provides orelse return null;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bare: std.ArrayListUnmanaged(usize) = .empty;
    for (entries, 0..) |entry, index| {
        if (isBareSoname(entry)) try bare.append(a, index);
    }
    if (bare.items.len == 0) return null;

    var matches = try a.alloc(std.ArrayListUnmanaged([]u8), bare.items.len);
    for (matches) |*list| list.* = .empty;
    var walker = try pkgdir.walk(a);
    defer walker.deinit();
    while (try walker.next(self.io)) |entry| {
        if (self.active_operation) |operation| try operation.checkCancelled();
        if (entry.kind != .file) continue;
        var matched = false;
        for (bare.items) |index| {
            if (std.mem.startsWith(u8, entry.basename, entries[index])) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;
        const stat = entry.dir.statFile(self.io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file) continue;
        for (bare.items, 0..) |index, list_index| {
            if (!std.mem.startsWith(u8, entry.basename, entries[index])) continue;
            try matches[list_index].append(a, try a.dupe(u8, entry.path));
        }
    }

    var output: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (output.items) |entry| self.allocator.free(entry);
        output.deinit(self.allocator);
    }
    for (entries, 0..) |entry, index| {
        const list_index = std.mem.indexOfScalar(usize, bare.items, index) orelse {
            try appendDupe(&output, self.allocator, entry);
            continue;
        };
        const list = &matches[list_index];
        std.mem.sort([]u8, list.items, {}, pathLessThan);
        if (list.items.len == 0) {
            warn(self, package_name, "Cannot find library listed in 'provides': {s}", .{entry});
        }
        var versioned: std.ArrayListUnmanaged([]u8) = .empty;
        for (list.items) |path| {
            if (self.active_operation) |operation| try operation.checkCancelled();
            var info = (try readElfDynamic(a, self.io, pkgdir, path)) orelse {
                warn(self, package_name, "Library listed in 'provides' is not a shared object: {s}", .{entry});
                continue;
            };
            defer info.deinit();
            if (!info.isShared()) {
                warn(self, package_name, "Library listed in 'provides' is not a shared object: {s}", .{entry});
                continue;
            }
            const soname = info.soname orelse {
                warn(self, package_name, "Library listed in 'provides' is not versioned: {s}", .{entry});
                continue;
            };
            const value = try std.fmt.allocPrint(a, "{s}={s}-{d}", .{ entry, versionSuffix(soname), info.class });
            var duplicate = false;
            for (versioned.items) |existing| {
                if (std.mem.eql(u8, existing, value)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try versioned.append(a, value);
        }
        if (versioned.items.len == 0) {
            try appendDupe(&output, self.allocator, entry);
        } else {
            for (versioned.items) |value| try appendDupe(&output, self.allocator, value);
        }
    }
    return try output.toOwnedSlice(self.allocator);
}

/// Versions bare `*.so` depends from the DT_NEEDED requirements of packaged
/// user-executable files, as makepkg's find_libdepends does. Each distinct
/// `<version>-<class>` observed for a soname produces one expanded entry;
/// requirements no packaged file links against stay bare with a warning.
/// Returns null when nothing needs expansion; otherwise every returned entry
/// is allocator-owned.
pub fn expandDepends(
    self: *PackageBuilder,
    package_name: []const u8,
    pkgdir: std.Io.Dir,
    depends: ?[][]const u8,
) !?[][]const u8 {
    const entries = depends orelse return null;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var has_bare = false;
    for (entries) |entry| {
        if (isBareSoname(entry)) {
            has_bare = true;
            break;
        }
    }
    if (!has_bare) return null;

    var files: std.ArrayListUnmanaged([]u8) = .empty;
    var walker = try pkgdir.walk(a);
    defer walker.deinit();
    while (try walker.next(self.io)) |entry| {
        if (self.active_operation) |operation| try operation.checkCancelled();
        if (entry.kind != .file) continue;
        const stat = entry.dir.statFile(self.io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file or stat.permissions.toMode() & 0o100 == 0) continue;
        try files.append(a, try a.dupe(u8, entry.path));
    }
    std.mem.sort([]u8, files.items, {}, pathLessThan);

    var requirements: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]u8)) = .empty;
    for (files.items) |path| {
        if (self.active_operation) |operation| try operation.checkCancelled();
        var info = (try readElfDynamic(a, self.io, pkgdir, path)) orelse continue;
        defer info.deinit();
        for (info.needed.items) |needed| {
            const base = sonameBase(needed) orelse continue;
            const value = try std.fmt.allocPrint(a, "{s}-{d}", .{ versionSuffix(needed), info.class });
            if (requirements.getPtr(base)) |list| {
                var duplicate = false;
                for (list.items) |existing| {
                    if (std.mem.eql(u8, existing, value)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try list.append(a, value);
            } else {
                var list: std.ArrayListUnmanaged([]u8) = .empty;
                try list.append(a, value);
                try requirements.put(a, try a.dupe(u8, base), list);
            }
        }
    }

    var output: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (output.items) |entry| self.allocator.free(entry);
        output.deinit(self.allocator);
    }
    for (entries) |entry| {
        const list = if (isBareSoname(entry)) requirements.getPtr(entry) else null;
        if (list) |values| {
            for (values.items) |value| {
                const expanded = try std.fmt.allocPrint(a, "{s}={s}", .{ entry, value });
                try appendDupe(&output, self.allocator, expanded);
            }
        } else {
            if (isBareSoname(entry)) {
                warn(self, package_name, "Library listed in 'depends' is not required by any files: {s}", .{entry});
            }
            try appendDupe(&output, self.allocator, entry);
        }
    }
    return try output.toOwnedSlice(self.allocator);
}

/// Builds a minimal but valid ELF image with one PT_LOAD covering the whole
/// file and one PT_DYNAMIC, for unit tests of the reader.
fn testElfImage(allocator: std.mem.Allocator, options: struct {
    wide: bool = true,
    endian: std.builtin.Endian = .little,
    elf_type: u16 = 3,
    soname: ?[]const u8 = "libdemo.so.1",
    needed: []const []const u8 = &.{"libother.so.2"},
}) ![]u8 {
    const endian = options.endian;
    const header_size: usize = if (options.wide) 64 else 52;
    const phentsize: usize = if (options.wide) 56 else 32;
    const dyn_entsize: usize = if (options.wide) 16 else 8;
    const phoff = header_size;
    const dynoff = phoff + 2 * phentsize;

    var strtab: std.ArrayListUnmanaged(u8) = .empty;
    defer strtab.deinit(allocator);
    try strtab.append(allocator, 0);
    var soname_offset: ?usize = null;
    if (options.soname) |name| {
        soname_offset = strtab.items.len;
        try strtab.appendSlice(allocator, name);
        try strtab.append(allocator, 0);
    }
    const needed_offsets = try allocator.alloc(usize, options.needed.len);
    defer allocator.free(needed_offsets);
    for (options.needed, 0..) |name, i| {
        needed_offsets[i] = strtab.items.len;
        try strtab.appendSlice(allocator, name);
        try strtab.append(allocator, 0);
    }
    const dyn_count = 2 + @as(usize, if (options.soname != null) 1 else 0) + options.needed.len + 1;
    const stroff = dynoff + dyn_count * dyn_entsize;
    const image = try allocator.alloc(u8, stroff + strtab.items.len);
    errdefer allocator.free(image);
    @memset(image, 0);

    image[0..4].* = "\x7fELF".*;
    image[4] = if (options.wide) 2 else 1;
    image[5] = if (endian == .little) 1 else 2;
    image[6] = 1;
    std.mem.writeInt(u16, image[16..18], options.elf_type, endian);
    std.mem.writeInt(u32, image[20..24], 1, endian);
    if (options.wide) {
        std.mem.writeInt(u64, image[32..40], phoff, endian);
        std.mem.writeInt(u16, image[54..56], @intCast(phentsize), endian);
        std.mem.writeInt(u16, image[56..58], 2, endian);
    } else {
        std.mem.writeInt(u32, image[28..32], @intCast(phoff), endian);
        std.mem.writeInt(u16, image[42..44], @intCast(phentsize), endian);
        std.mem.writeInt(u16, image[44..46], 2, endian);
    }
    for ([_]struct { kind: u32, offset: usize, size: usize }{
        .{ .kind = 1, .offset = 0, .size = image.len },
        .{ .kind = 2, .offset = dynoff, .size = dyn_count * dyn_entsize },
    }, 0..) |ph, i| {
        const phb = image[phoff + i * phentsize ..][0..phentsize];
        std.mem.writeInt(u32, phb[0..4], ph.kind, endian);
        if (options.wide) {
            std.mem.writeInt(u64, phb[8..16], @intCast(ph.offset), endian);
            std.mem.writeInt(u64, phb[16..24], @intCast(ph.offset), endian);
            std.mem.writeInt(u64, phb[32..40], @intCast(ph.size), endian);
            std.mem.writeInt(u64, phb[40..48], @intCast(ph.size), endian);
        } else {
            std.mem.writeInt(u32, phb[4..8], @intCast(ph.offset), endian);
            std.mem.writeInt(u32, phb[8..12], @intCast(ph.offset), endian);
            std.mem.writeInt(u32, phb[16..20], @intCast(ph.size), endian);
            std.mem.writeInt(u32, phb[20..24], @intCast(ph.size), endian);
        }
    }
    const putDynamic = struct {
        fn put(img: []u8, at: usize, tag: u64, val: u64, wide: bool, order: std.builtin.Endian) void {
            if (wide) {
                std.mem.writeInt(u64, img[at..][0..8], tag, order);
                std.mem.writeInt(u64, img[at + 8 ..][0..8], val, order);
            } else {
                std.mem.writeInt(u32, img[at..][0..4], @intCast(tag), order);
                std.mem.writeInt(u32, img[at + 4 ..][0..4], @intCast(val), order);
            }
        }
    }.put;
    var dyn_index: usize = 0;
    putDynamic(image, dynoff + dyn_index * dyn_entsize, 5, @intCast(stroff), options.wide, endian);
    dyn_index += 1;
    putDynamic(image, dynoff + dyn_index * dyn_entsize, 10, @intCast(strtab.items.len), options.wide, endian);
    dyn_index += 1;
    if (soname_offset) |offset| {
        putDynamic(image, dynoff + dyn_index * dyn_entsize, 14, @intCast(offset), options.wide, endian);
        dyn_index += 1;
    }
    for (needed_offsets) |offset| {
        putDynamic(image, dynoff + dyn_index * dyn_entsize, 1, @intCast(offset), options.wide, endian);
        dyn_index += 1;
    }
    putDynamic(image, dynoff + dyn_index * dyn_entsize, 0, 0, options.wide, endian);
    @memcpy(image[stroff..], strtab.items);
    return image;
}

test "soname ELF reader extracts class, type, soname and needed libraries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ true, false }) |wide| {
        const image = try testElfImage(allocator, .{ .wide = wide });
        defer allocator.free(image);
        try tmp.dir.writeFile(io, .{ .sub_path = "libdemo.so.1", .data = image });
        var info = (try readElfDynamic(allocator, io, tmp.dir, "libdemo.so.1")) orelse return error.TestUnexpectedResult;
        defer info.deinit();
        try std.testing.expectEqual(@as(u8, if (wide) 64 else 32), info.class);
        try std.testing.expect(info.isShared());
        try std.testing.expectEqualStrings("libdemo.so.1", info.soname.?);
        try std.testing.expectEqual(@as(usize, 1), info.needed.items.len);
        try std.testing.expectEqualStrings("libother.so.2", info.needed.items[0]);
    }
}

test "soname ELF reader handles big-endian files and absent sonames" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image = try testElfImage(allocator, .{ .endian = .big, .soname = null, .needed = &.{ "liba.so.1", "libb.so.2" } });
    defer allocator.free(image);
    try tmp.dir.writeFile(io, .{ .sub_path = "libbig.so", .data = image });
    var info = (try readElfDynamic(allocator, io, tmp.dir, "libbig.so")) orelse return error.TestUnexpectedResult;
    defer info.deinit();
    try std.testing.expectEqual(@as(u8, 64), info.class);
    try std.testing.expect(info.soname == null);
    try std.testing.expectEqual(@as(usize, 2), info.needed.items.len);
    try std.testing.expectEqualStrings("liba.so.1", info.needed.items[0]);
    try std.testing.expectEqualStrings("libb.so.2", info.needed.items[1]);
}

test "soname ELF reader rejects non-ELF, truncated and executable files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "script", .data = "#!/bin/sh\nexit 0\n" });
    try std.testing.expect((try readElfDynamic(allocator, io, tmp.dir, "script")) == null);
    const image = try testElfImage(allocator, .{ .elf_type = 2 });
    defer allocator.free(image);
    try tmp.dir.writeFile(io, .{ .sub_path = "truncated", .data = image[0..10] });
    try std.testing.expect((try readElfDynamic(allocator, io, tmp.dir, "truncated")) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "executable", .data = image });
    var info = (try readElfDynamic(allocator, io, tmp.dir, "executable")) orelse return error.TestUnexpectedResult;
    defer info.deinit();
    try std.testing.expect(!info.isShared());
    try std.testing.expect((try readElfDynamic(allocator, io, tmp.dir, "missing")) == null);
}

test "soname helpers follow makepkg shell expansions" {
    try std.testing.expectEqualStrings("1", versionSuffix("libdemo.so.1"));
    try std.testing.expectEqualStrings("1.2.3", versionSuffix("libfoo.so.1.2.3"));
    try std.testing.expectEqualStrings("libfoo.so", versionSuffix("libfoo.so"));
    try std.testing.expectEqualStrings("libdemo.so", sonameBase("libdemo.so.1").?);
    try std.testing.expectEqualStrings("libfoo.so", sonameBase("libfoo.so").?);
    try std.testing.expectEqualStrings("libfoo.so", sonameBase("libfoo.so.1.2").?);
    try std.testing.expect(sonameBase("libfoo.so.1a") == null);
    try std.testing.expect(isBareSoname("libfoo.so"));
    try std.testing.expect(!isBareSoname("libfoo.so=1-64"));
    try std.testing.expect(!isBareSoname("lib:libfoo.so"));
    try std.testing.expect(!isBareSoname("foo"));
}
