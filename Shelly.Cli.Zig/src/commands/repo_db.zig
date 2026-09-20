//! `shelly repo-db add|remove|list|verify`: the CLI surface of
//! `Zigalpm.repo.Database`. Lines are bare text with a fixed shape: stdout
//! carries progress and results, stderr carries warnings and errors.

const std = @import("std");
const Zigalpm = @import("Zigalpm");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");
const spec = @import("../cli/spec.zig");
const test_support = @import("test_support.zig");

const Database = Zigalpm.repo.Database;
const Failure = Zigalpm.repo.database.Failure;
const Warning = Zigalpm.source_pgp_verifier.Warning;
const archive = Zigalpm.shared.archive;

const command_prefix = "shelly repo-db ";

const Operation = enum { add, remove, list, verify };

/// Paths named by the error messages. Only `db_path` is available before
/// `Database.open` succeeds.
const Targets = struct {
    db_path: []const u8,
    db_dir: []const u8 = "",
    lock_path: []const u8 = "",

    fn fromDatabase(db: *const Database) Targets {
        return .{
            .db_path = db.db_path,
            .db_dir = db.db_dir,
            .lock_path = db.lock_path,
        };
    }
};

pub fn dispatch(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !?u8 {
    const operation = operationForPath(invocation.command.path) orelse return null;

    if (invocation.positionals.len == 0)
        return try reportUsage(context, "Specify the repository database path. See the command help for usage.");
    for (invocation.positionals) |positional| {
        if (isBlank(positional))
            return try reportUsage(context, "Package database arguments cannot be empty.");
    }
    if (optionValue(invocation, "--key") != null and !optionEnabled(invocation, "--sign"))
        return try reportUsage(context, "Option '--key' requires '--sign'.");

    var db = Database.open(context.allocator, context.io, invocation.positionals[0]) catch |err|
        return try reportError(context, err, .{ .db_path = invocation.positionals[0] }, "update");
    defer db.deinit();

    return switch (operation) {
        .add => try executeAdd(context, invocation, &db),
        .remove => try executeRemove(context, invocation, &db),
        .list => try executeList(context, invocation, &db),
        .verify => try executeVerify(context, &db),
    };
}

fn executeAdd(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    db: *Database,
) !u8 {
    const options: Zigalpm.repo.AddOptions = .{
        .new_only = optionEnabled(invocation, "--new"),
        .prevent_downgrade = optionEnabled(invocation, "--prevent-downgrade"),
        .remove_old_files = optionEnabled(invocation, "--remove-old-files"),
        // Repositories here are consumed by clients that cannot fetch a
        // separate .sig per package, so embedding is on unless declined.
        .include_sigs = !optionEnabled(invocation, "--exclude-sigs"),
        .wait_for_lock = optionEnabled(invocation, "--wait"),
        .signer = signerFor(context, invocation),
        .sign_key = optionValue(invocation, "--key"),
    };
    var summary = db.addPackages(invocation.positionals[1..], options) catch |err|
        return try reportError(context, err, Targets.fromDatabase(db), "update");
    defer summary.deinit(context.allocator);

    const quiet = optionEnabled(invocation, "--quiet");
    for (summary.added) |entry| {
        if (quiet) continue;
        try context.stdout.print("adding '{s}' to repository '{s}'.\n", .{ entry.filename, db.db_filename });
    }
    for (summary.skipped_existing) |entry_dir| {
        try context.stderr.print("An entry for '{s}' already existed.\n", .{entry_dir});
    }
    for (summary.skipped_newer) |name| {
        try context.stderr.print("A newer version for '{s}' is already present in database.\n", .{name});
    }
    for (summary.failures) |failure| try printFailure(context, failure);

    if (summary.failures.len > 0) {
        try context.stderr.print("The repository database was not modified because the package checks failed. Resolve the reported package errors before trying again.\n", .{});
        return 1;
    }
    if (!summary.published) {
        try context.stdout.print("No changes made to package database.\n", .{});
        return 0;
    }
    if (summary.published_empty)
        try context.stdout.print("No packages remain, creating empty database.\n", .{});
    return 0;
}

fn executeRemove(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    db: *Database,
) !u8 {
    const options: Zigalpm.repo.RemoveOptions = .{
        .remove_old_files = optionEnabled(invocation, "--remove-old-files"),
        .wait_for_lock = optionEnabled(invocation, "--wait"),
        .signer = signerFor(context, invocation),
        .sign_key = optionValue(invocation, "--key"),
    };
    var summary = db.removePackages(invocation.positionals[1..], options) catch |err|
        return try reportError(context, err, Targets.fromDatabase(db), "update");
    defer summary.deinit(context.allocator);

    const quiet = optionEnabled(invocation, "--quiet");
    for (summary.removed_entries) |entry_dir| {
        if (quiet) continue;
        try context.stdout.print("removing '{s}' from repository '{s}'.\n", .{ entry_dir, db.db_filename });
    }
    for (summary.not_found) |name| {
        try context.stderr.print("Could not remove '{0f}' because it is not present in repository database '{1f}'. Check the package name and database path.\n", .{ @import("diagnostics").safe(name), @import("diagnostics").safe(db.db_filename) });
    }
    if (summary.not_found.len > 0) {
        try context.stderr.print("The repository database was not modified because the package checks failed. Resolve the reported package errors before trying again.\n", .{});
        return 1;
    }
    if (summary.published_empty)
        try context.stdout.print("No packages remain, creating empty database.\n", .{});
    return 0;
}

fn executeList(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
    db: *Database,
) !u8 {
    const entries = db.listEntries() catch |err|
        return try reportError(context, err, Targets.fromDatabase(db), "read");
    defer Zigalpm.repo.database.freeEntries(context.allocator, entries);

    if (invocation.globals.json) {
        try writeEntriesJson(context.stdout, entries);
        try context.stdout.writeByte('\n');
        return 0;
    }
    for (entries) |entry| try context.stdout.print("{s} {s}\n", .{ entry.name, entry.version });
    return 0;
}

fn executeVerify(
    context: *runtime.RuntimeContext,
    db: *Database,
) !u8 {
    // No key ids are pinned, so only an ultimately trusted key verifies.
    const verifier: Zigalpm.source_pgp_verifier.Verifier = .{
        .allocator = context.allocator,
        .io = context.io,
        .environ = context.environ,
    };
    var summary = db.verifySignatures(verifier) catch |err|
        return try reportError(context, err, Targets.fromDatabase(db), "verify");
    defer summary.deinit(context.allocator);

    for (summary.results) |result| {
        if (!result.archive_present) continue;
        try context.stdout.print("Verifying database signature...\n", .{});
        if (!result.signature_present) {
            try context.stdout.print("The repository database has no signature. Verification was skipped; its authenticity has not been verified.\n", .{});
            continue;
        }
        if (!result.verified) {
            try context.stderr.print("Could not verify the repository database signature for the selected path. Obtain a valid database and signature from the repository.\n", .{});
            return 1;
        }
        try context.stdout.print("Database signature file verified.\n", .{});
        try printWarning(context, result.warning);
    }
    return 0;
}

fn operationForPath(path: []const u8) ?Operation {
    if (!std.mem.startsWith(u8, path, command_prefix)) return null;
    const name = path[command_prefix.len..];
    inline for (std.meta.tags(Operation)) |operation| {
        if (std.mem.eql(u8, name, @tagName(operation))) return operation;
    }
    return null;
}

fn signerFor(
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) ?Zigalpm.package_signer.Signer {
    if (!optionEnabled(invocation, "--sign")) return null;
    return .{
        .allocator = context.allocator,
        .io = context.io,
        .environ = context.environ,
    };
}

fn printFailure(context: *runtime.RuntimeContext, failure: Failure) !void {
    const path = failure.package_path;
    switch (failure.kind) {
        .missing_file => try context.stderr.print("Could not find package archive '{0f}'. Check the path and try again.\n", .{@import("diagnostics").safe(path)}),
        .not_a_package => try context.stderr.print("Could not add '{0f}' to the repository because it is not a supported package archive. Select a built package archive.\n", .{@import("diagnostics").safe(path)}),
        .invalid_package => try context.stderr.print("Could not add '{0f}' to the repository because the archive has no .PKGINFO metadata. Rebuild or obtain a complete package archive.\n", .{@import("diagnostics").safe(path)}),
        .armored_signature => try context.stderr.print("Could not add the signature for '{0f}' because it is ASCII-armored. Supply a binary detached signature.\n", .{@import("diagnostics").safe(path)}),
        .oversized_signature => try context.stderr.print("Could not add the signature for '{0f}' because it exceeds the 16,384-byte limit. Supply a supported detached signature.\n", .{@import("diagnostics").safe(path)}),
    }
}

fn printWarning(context: *runtime.RuntimeContext, warning: Warning) !void {
    switch (warning) {
        .none => {},
        .expired_signature => try context.stderr.print(
            "The signature for the selected path verifies cryptographically, but has expired. Obtain a current signature from the repository.\n",
            .{},
        ),
        .expired_key => try context.stderr.print(
            "The signature for the selected path verifies cryptographically, but its signing key has expired. Obtain an updated signing key and signature from the repository.\n",
            .{},
        ),
    }
}

fn writeEntriesJson(writer: *std.Io.Writer, entries: []Zigalpm.repo.EntryInfo) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (entries) |entry| {
        try json.beginObject();
        try json.objectField("Name");
        try json.write(entry.name);
        try json.objectField("Version");
        try json.write(entry.version);
        try json.objectField("FileName");
        try json.write(entry.filename);
        try json.endObject();
    }
    try json.endArray();
}

fn reportUsage(context: *runtime.RuntimeContext, message: []const u8) !u8 {
    try context.stderr.print("{s}\n", .{message});
    return 1;
}

fn reportError(
    context: *runtime.RuntimeContext,
    err: anyerror,
    targets: Targets,
    verb: []const u8,
) !u8 {
    switch (err) {
        error.LockHeld => {
            try context.stderr.print("Could not lock repository database '{0f}' using '{1f}'. If another repository update is running, wait for it to finish.\n", .{ @import("diagnostics").safe(targets.db_path), @import("diagnostics").safe(targets.lock_path) });
            return 2;
        },
        error.DatabaseNotFound => try context.stderr.print(
            "Could not find repository database '{0f}'. Check the path and try again.\n",
            .{@import("diagnostics").safe(targets.db_path)},
        ),
        error.UnsupportedExtension => try context.stderr.print(
            "Unsupported repository database filename '{0f}'. Use a filename ending in.db.tar.<compression> with a supported compression format.\n",
            .{@import("diagnostics").safe(targets.db_path)},
        ),
        error.DirectoryMissing => try context.stderr.print(
            "Directory '{0f}' does not exist. Create it or select an existing directory.\n",
            .{@import("diagnostics").safe(targets.db_dir)},
        ),
        error.InvalidDatabase => try context.stderr.print(
            "Could not read repository database '{0f}' because it is corrupted. Restore it from a known-good copy or rebuild it from the package archives.\n",
            .{@import("diagnostics").safe(targets.db_path)},
        ),
        else => try context.stderr.print(
            "Could not {0f} the package database: {1s}\n\nTechnical details: {2s}\n",
            .{ @import("diagnostics").safe(verb), @import("diagnostics").cause(err), @errorName(err) },
        ),
    }
    return 1;
}

fn optionEnabled(invocation: *const parser.Invocation, name: []const u8) bool {
    for (invocation.options) |option| {
        if (!std.mem.eql(u8, option.name, name)) continue;
        const value = option.value orelse return true;
        return !std.ascii.eqlIgnoreCase(value, "false");
    }
    return false;
}

fn optionValue(invocation: *const parser.Invocation, name: []const u8) ?[]const u8 {
    for (invocation.options) |option| {
        if (std.mem.eql(u8, option.name, name)) return option.value;
    }
    return null;
}

fn isBlank(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len == 0;
}

fn parseInvocation(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) !parser.Invocation {
    const manifest = try spec.Manifest.load(allocator);
    const outcome = try parser.parse(allocator, &manifest, arguments);
    try std.testing.expect(outcome == .dispatch);
    return outcome.dispatch;
}

fn expectOption(invocation: *const parser.Invocation, name: []const u8) !void {
    try std.testing.expect(optionEnabled(invocation, name));
}

const seeded_desc =
    \\%FILENAME%
    \\demo-1.0-1-any.pkg.tar.zst
    \\%NAME%
    \\demo
    \\%VERSION%
    \\1.0-1
    \\
;

test "repo-db catalog exposes add remove and list variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const add = manifest.findByPath("shelly repo-db add").?;
    try std.testing.expectEqual(@as(u8, 'G'), add.actionCode);
    try std.testing.expectEqual(@as(?u8, 'a'), add.typeCode);
    inline for (.{ "add", "remove", "list", "verify" }) |name| {
        const path = "shelly repo-db " ++ name;
        const command = manifest.findByPath(path) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u8, 'G'), command.actionCode);
        try std.testing.expect(command.typeCode != null);
    }

    const list = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "repo-db", "list", "demo.db.tar.zst" },
    );
    try std.testing.expect(list == .dispatch);
    try std.testing.expectEqualStrings("shelly repo-db list", list.dispatch.command.path);
    try std.testing.expectEqual(@as(usize, 1), list.dispatch.positionals.len);
    try std.testing.expectEqualStrings("demo.db.tar.zst", list.dispatch.positionals[0]);
}

test "repo-db add parses database and package positionals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const invocation = try parseInvocation(arena.allocator(), &.{
        "repo-db",                     "add",
        "demo.db.tar.zst",             "demo-1.0-1-any.pkg.tar.zst",
        "extra-1.0-1-any.pkg.tar.zst", "-p",
        "-R",                          "-w",
        "-s",                          "-k",
        "DEADBEEF",
    });

    try std.testing.expectEqual(@as(usize, 3), invocation.positionals.len);
    try std.testing.expectEqualStrings("demo.db.tar.zst", invocation.positionals[0]);
    try std.testing.expectEqualStrings("demo-1.0-1-any.pkg.tar.zst", invocation.positionals[1]);
    try std.testing.expectEqualStrings("extra-1.0-1-any.pkg.tar.zst", invocation.positionals[2]);

    try expectOption(&invocation, "--prevent-downgrade");
    try expectOption(&invocation, "--remove-old-files");
    try expectOption(&invocation, "--wait");
    try expectOption(&invocation, "--sign");
    const key = optionValue(&invocation, "--key");
    try std.testing.expect(key != null);
    try std.testing.expectEqualStrings("DEADBEEF", key.?);
}

test "repo-db requires a database and at least one package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const without_database = try parser.parse(arena.allocator(), &manifest, &.{ "repo-db", "add" });
    try std.testing.expect(without_database == .failure);
    try std.testing.expect(std.mem.indexOf(u8, without_database.failure.message, "'database'") != null);

    // Arity accounting blames the first argument whose minimum cannot be met,
    // so a missing <packages> is reported against <database>.
    const without_packages = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "repo-db", "add", "demo.db.tar.zst" },
    );
    try std.testing.expect(without_packages == .failure);
    try std.testing.expect(std.mem.indexOf(u8, without_packages.failure.message, "Command 'shelly repo-db add'") != null);
}

test "repo-db remove requires a database and one or more names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try spec.Manifest.load(arena.allocator());

    const without_database = try parser.parse(arena.allocator(), &manifest, &.{ "repo-db", "remove" });
    try std.testing.expect(without_database == .failure);
    try std.testing.expect(std.mem.indexOf(u8, without_database.failure.message, "'database'") != null);

    const without_names = try parser.parse(
        arena.allocator(),
        &manifest,
        &.{ "repo-db", "remove", "demo.db.tar.zst" },
    );
    try std.testing.expect(without_names == .failure);
    try std.testing.expect(std.mem.indexOf(u8, without_names.failure.message, "Command 'shelly repo-db remove'") != null);
}

test "repo-db list prints entries in plain and JSON output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The database module resolves relative paths against the process cwd, so
    // the fixture is addressed absolutely.
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "demo.db.tar.zst" });
    defer std.testing.allocator.free(db_path);
    try archive.writeFixture(std.testing.allocator, db_path, .zstd, &.{
        .{ .path = "demo-1.0-1/desc", .contents = seeded_desc },
    });

    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    const plain = try parseInvocation(tc.arena.allocator(), &.{ "repo-db", "list", db_path });
    try std.testing.expectEqual(@as(?u8, 0), try dispatch(&tc.context, &plain));
    try std.testing.expectEqualStrings("demo 1.0-1\n", tc.stdout.writer.buffered());

    tc.stdout.writer.end = 0;
    const as_json = try parseInvocation(tc.arena.allocator(), &.{ "repo-db", "list", db_path, "--json" });
    try std.testing.expectEqual(@as(?u8, 0), try dispatch(&tc.context, &as_json));
    try std.testing.expectEqualStrings(
        "[{\"Name\":\"demo\",\"Version\":\"1.0-1\",\"FileName\":\"demo-1.0-1-any.pkg.tar.zst\"}]\n",
        tc.stdout.writer.buffered(),
    );
}

test "repo-db maps lock contention to exit code 2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root, "demo.db.tar.zst" });
    defer std.testing.allocator.free(db_path);
    const lock_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.lock", .{db_path});
    defer std.testing.allocator.free(lock_path);

    // flocks live on the open file description, so a second descriptor of the
    // sidecar contends with the database operation in this same process.
    var holder = try std.Io.Dir.cwd().createFile(std.testing.io, lock_path, .{
        .read = true,
        .truncate = false,
    });
    defer holder.close(std.testing.io);
    try std.testing.expect(try holder.tryLock(std.testing.io, .exclusive));

    var tc: test_support.TestContext = .{};
    tc.init();
    defer tc.deinit();

    const add = try parseInvocation(tc.arena.allocator(), &.{
        "repo-db", "add", db_path, "demo-1.0-1-any.pkg.tar.zst",
    });
    try std.testing.expectEqual(@as(?u8, 2), try dispatch(&tc.context, &add));
    const printed = tc.stderr.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, printed, "Could not lock repository database") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, lock_path) != null);
}
