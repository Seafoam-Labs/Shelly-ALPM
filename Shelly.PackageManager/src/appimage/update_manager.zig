const std = @import("std");
const appimage = @import("bindings.zig").appimage;
const builtin = @import("builtin");
const appimage_manager = @import("manager.zig");
const http_client = @import("std.http.Client");
const xdg_paths = @import("../shared/xdg_paths.zig").xdg_paths;
const downloader = @import("../shared/downloader.zig");

pub const UpdateManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    install_directory: []const u8,
    local_db_path: []const u8,

    pub fn configure_updates(self: UpdateManager, update_info: []const u8, name: []const u8, update_type: appimage.UpdateType, allow_prerelease: bool) !bool {
        std.log.info("Configuring updates for {s} {s}, type: {s}, allowPrerelease: {}", .{ name, update_info, @tagName(update_type), allow_prerelease });

        const manager = appimage_manager.AppImageManager{
            .allocator = self.allocator,
            .io = self.io,
            .environ = self.environ,
            .install_directory = self.install_directory,
            .local_db_path = self.local_db_path,
        };

        const app_images = try manager.getAppImagesFromLocalDb();
        defer manager.freeAppImages(app_images);

        var found_index: ?usize = null;
        for (app_images, 0..) |app, i| {
            if (std.ascii.eqlIgnoreCase(app.name, name)) {
                found_index = i;
                break;
            }
        }

        const idx = found_index orelse return false;
        var app = app_images[idx];
        try configure_update(update_info, update_type, &app, allow_prerelease);
        try manager.addAppImageToLocalDb(app);
        return true;
    }

    fn configure_update(update_info: []const u8, update_type: appimage.UpdateType, app: *appimage.AppImage, allow_prerelease: bool) !void {
        app.allow_prerelease = allow_prerelease;

        switch (update_type) {
            .none => {
                app.update_type = .none;
                app.update_url = "";
                app.repo_owner = null;
                app.repo_name = null;
            },
            .static_url => {
                app.update_url = update_info;
                app.update_type = update_type;
            },
            .forgejo => {
                if (std.mem.indexOf(u8, update_info, "//")) |idx| {
                    const after_scheme = update_info[idx + 2 ..];
                    if (countChar(after_scheme, '/') == 2) {
                        app.update_url = update_info;
                        app.update_type = update_type;
                    } else {
                        // std.log.warn("Could not parse update info. Please use the format: https://<domain>/<user>/<repo>");
                    }
                } else {
                    // std.log.warn("Could not parse update info. Please use the format: https://<domain>/<user>/<repo>");
                }
            },
            .github, .gitlab, .codeberg => {
                if (update_type == .gitlab) {
                    if (parse_gitlab_project(update_info)) |project| {
                        app.update_type = update_type;
                        if (project.is_shorthand) {
                            const idx = std.mem.indexOf(u8, project.project_path, "/").?;
                            app.repo_owner = project.project_path[0..idx];
                            app.repo_name = project.project_path[idx + 1 ..];
                            app.update_url = "";
                        } else {
                            app.update_url = update_info;
                            app.repo_owner = null;
                            app.repo_name = null;
                        }
                    } else {
                        // std.log.warn("Could not parse update info. Please use owner/repo or https://<domain>/<group>/<repo>");
                    }
                } else if (countChar(update_info, '/') == 1) {
                    const idx = std.mem.indexOf(u8, update_info, "/").?;
                    app.repo_owner = update_info[0..idx];
                    app.repo_name = update_info[idx + 1 ..];
                    app.update_type = update_type;
                } else {
                    // std.log.warn("Could not parse update info. Please use the format: <user>/<repo> (e.g., github.com/user/repo or gitlab.com/user/repo");
                }
            },
        }
    }

    fn countChar(haystack: []const u8, needle: u8) usize {
        var count: usize = 0;
        for (haystack) |c| {
            if (c == needle) count += 1;
        }
        return count;
    }

    pub fn get_updates(self: UpdateManager) ![]appimage.AppImageUpdate {
        const apps = try appimage_manager.AppImageManager.getAppImagesFromLocalDb();
        var updates: []appimage.AppImageUpdate = &[]appimage.AppImageUpdate{};
        for (apps) |app| {
            const app_update = try self.get_update(app);
            if (app_update.is_update_available) |u| {
                updates = try std.mem.concat(self.allocator, appimage.AppImageUpdate, updates, u);
            }
        }
        return updates;
    }

    pub fn get_update(self: UpdateManager, app: *appimage.AppImage) !appimage.AppImageUpdate {
        switch (app.update_type) {
            .none => return null,
            .static_url => {
                return self.check_static_url_update(app.update_url.?, app.name.?, app.version);
            },
            .github => {
                return self.check_github_update(app.repo_owner.?, app.repo_name.?, app.name, app.version, app.allow_prerelease);
            },
            .gitlab => {
                if (app.update_url.len > 0) {
                    return self.check_gitlab_update(app.update_url, app.name, app.version, app.allow_prerelease);
                }
                const update_info = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ app.repo_owner.?, app.repo_name.? });
                defer self.allocator.free(update_info);
                return self.check_gitlab_update(update_info, app.name, app.version, app.allow_prerelease);
            },
            .codeberg => {
                return self.check_codeberg_update(app.repo_owner.?, app.repo_name.?, app.name, app.version, app.allow_prerelease);
            },
            .forgejo => {
                return self.check_forgejo_update(app.update_url, app.name, app.version, app.allow_prerelease);
            },
        }
    }

    pub fn update(self: UpdateManager, appimage_ptr: *appimage.AppImageUpdate) !bool {
        const manager = appimage_manager.AppImageManager{
            .allocator = self.allocator,
            .io = self.io,
            .environ = self.environ,
            .install_directory = self.install_directory,
            .local_db_path = self.local_db_path,
        };

        const apps = try manager.getAppImagesFromLocalDb();
        defer manager.freeAppImages(apps);

        var found_index: ?usize = null;
        for (apps, 0..) |a, i| {
            if (std.ascii.eqlIgnoreCase(a.name, appimage_ptr.name)) {
                found_index = i;
                break;
            }
        }

        const app_to_update = if (found_index) |i| apps[i] else {
            std.log.debug("AppImage '{s}' not found in local database.", .{appimage_ptr.name});
            return false;
        };

        std.log.info("Updating {s}", .{app_to_update.name});

        if (appimage_ptr.download_url.len == 0) {
            std.log.debug("No download URL found for {s}.", .{appimage_ptr.name});
            return false;
        }

        const current_filename = try std.fmt.allocPrint(self.allocator, "{s}.AppImage", .{app_to_update.name});
        defer self.allocator.free(current_filename);
        const current_path = try std.fs.path.join(self.allocator, &.{ self.install_directory, current_filename });
        defer self.allocator.free(current_path);

        const current_exists = std.Io.Dir.cwd().statFile(self.io, current_path, .{}) catch null;
        if (current_exists == null) {
            std.log.debug("Current AppImage not found at {s}.", .{current_path});
            return false;
        }

        const cache_home = try xdg_paths.xdgCacheHome(self.allocator, self.environ);
        defer self.allocator.free(cache_home);
        const backup_dir = try std.fs.path.join(self.allocator, &.{ cache_home, "shelly", appimage_ptr.name });
        defer self.allocator.free(backup_dir);

        const backup_filename = try std.fmt.allocPrint(
            self.allocator,
            "{s}-{s}.AppImage.bak",
            .{ app_to_update.name, app_to_update.version },
        );
        defer self.allocator.free(backup_filename);
        const backup_path = try std.fs.path.join(self.allocator, &.{ backup_dir, backup_filename });
        defer self.allocator.free(backup_path);

        const download_path = try std.fmt.allocPrint(self.allocator, "{s}.rep", .{current_path});
        defer self.allocator.free(download_path);

        try std.Io.Dir.cwd().createDirPath(self.io, backup_dir);

        std.log.info("Downloading update for {s}...", .{appimage_ptr.name});

        var dl = downloader.CoreDownloader.init(self.allocator, self.io, .default());
        defer dl.deinit();

        const dl_result = dl.downloadToFile(appimage_ptr.download_url, download_path, false);
        switch (dl_result) {
            .failure => |err| {
                std.log.err("Failed to download update for {s}: {s}", .{ appimage_ptr.name, @errorName(err) });
                std.Io.Dir.cwd().deleteFile(self.io, download_path) catch {};
                return false;
            },
            else => {},
        }

        try manager.setExecutable(download_path);

        const new_metadata = (try manager.extractMetadata(download_path)) orelse {
            std.Io.Dir.cwd().deleteFile(self.io, download_path) catch {};
            return false;
        };
        defer manager.freeAppImage(new_metadata);

        const download_filename = std.fs.path.basename(appimage_ptr.download_url);
        if (!isCorrectArchitecture(download_filename)) {
            std.log.warn("The downloaded AppImage might not match your system architecture.", .{});
        }

        std.log.info("Backing up current version to {s}...", .{backup_path});
        try manager.copyFile(current_path, backup_path);

        manager.copyFile(download_path, current_path) catch |err| {
            std.log.err("Error installing new version: {s}. Rolling back...", .{@errorName(err)});
            manager.copyFile(backup_path, current_path) catch {};
            std.Io.Dir.cwd().deleteFile(self.io, download_path) catch {};
            return false;
        };
        std.Io.Dir.cwd().deleteFile(self.io, download_path) catch {};

        const updated_app = appimage.AppImage{
            .name = app_to_update.name,
            .version = appimage_ptr.version,
            .raw_update_info = app_to_update.raw_update_info,
            .icon_name = new_metadata.icon_name,
            .description = new_metadata.description,
            .desktop_name = app_to_update.desktop_name,
            .size_on_disk = new_metadata.size_on_disk,
            .command_line_args = app_to_update.command_line_args,
            .path = app_to_update.path,
            .update_url = app_to_update.update_url,
            .update_type = app_to_update.update_type,
            .repo_owner = app_to_update.repo_owner,
            .repo_name = app_to_update.repo_name,
            .allow_prerelease = app_to_update.allow_prerelease,
        };
        try manager.addAppImageToLocalDb(updated_app);

        return true;
    }

    pub fn check_static_url_update(self: UpdateManager, url: []const u8, app_name: []const u8, current_version: []const u8) !?appimage.AppImageUpdate {
        const uri = std.Uri.parse(url) catch return null;

        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var req = client.request(.HEAD, uri, .{
            .headers = .{},
        }) catch return null;
        defer req.deinit();

        req.sendBodiless() catch return null;

        var redirect_buffer: [8 * 1024]u8 = undefined;
        const response = req.receiveHead(&redirect_buffer) catch return null;

        if (response.head.status.class() != .success) return null;

        var etag: ?[]const u8 = null;
        var last_modified: ?[]const u8 = null;

        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
                etag = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "last-modified")) {
                last_modified = header.value;
            }
        }

        const raw_version = if (etag != null) etag.? else if (last_modified != null) last_modified.? else "";
        return build_static_url(self.allocator, app_name, url, current_version, raw_version);
    }

    fn build_static_url(allocator: std.mem.Allocator, app_name: []const u8, url: []const u8, current_version: []const u8, raw_version: []const u8) !?appimage.AppImageUpdate {
        const version = std.mem.trim(u8, raw_version, "\"");
        return appimage.AppImageUpdate{
            .name = try allocator.dupe(u8, app_name),
            .version = try allocator.dupe(u8, version),
            .download_url = try allocator.dupe(u8, url),
            .is_update_available = try version_unknown_or_dif(current_version, version),
        };
    }

    fn getSystemArchitecture() []const u8 {
        const arch = builtin.cpu.arch;
        return switch (arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .x86 => "x86",
            .arm => "arm",
            else => @tagName(arch),
        };
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (haystack.len < needle.len) return false;

        const max_i = haystack.len - needle.len + 1;
        for (0..max_i) |i| {
            var match = true;
            for (0..needle.len) |j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    fn anyContains(haystack: []const u8, aliases: []const []const u8) bool {
        for (aliases) |alias| {
            if (containsIgnoreCase(haystack, alias)) return true;
        }
        return false;
    }

    fn isCorrectArchitecture(asset_name: []const u8) bool {
        const system_arch = getSystemArchitecture();

        const x8664_aliases = [_][]const u8{ "x86_64", "amd64", "x64" };
        const aarch64_aliases = [_][]const u8{ "aarch64", "arm64", "armv8" };
        const i386_aliases = [_][]const u8{ "i386", "i686", "x86" };
        const armhf_aliases = [_][]const u8{ "armhf", "armv7l", "arm" };

        var target_aliases: []const []const u8 = undefined;

        if (std.mem.eql(u8, system_arch, "x86_64")) {
            target_aliases = x8664_aliases[0..];
        } else if (std.mem.eql(u8, system_arch, "aarch64")) {
            target_aliases = aarch64_aliases[0..];
        } else if (std.mem.eql(u8, system_arch, "i386")) {
            target_aliases = i386_aliases[0..];
        } else if (std.mem.eql(u8, system_arch, "arm")) {
            target_aliases = armhf_aliases[0..];
        } else {
            const single_arch = [_][]const u8{system_arch};
            target_aliases = single_arch[0..];
        }

        if (anyContains(asset_name, target_aliases)) {
            return true;
        }

        const all_alias_groups = [_][]const []const u8{
            x8664_aliases[0..],
            aarch64_aliases[0..],
            i386_aliases[0..],
            armhf_aliases[0..],
        };

        for (all_alias_groups) |group| {
            for (group) |alias| {
                var is_in_target = false;
                for (target_aliases) |ta| {
                    if (std.mem.eql(u8, alias, ta)) {
                        is_in_target = true;
                        break;
                    }
                }
                if (!is_in_target) {
                    if (containsIgnoreCase(asset_name, alias)) {
                        return false;
                    }
                }
            }
        }

        return true;
    }

    pub fn gitea_to_releases_api(allocator: std.mem.Allocator, domain: []const u8, owner: []const u8, repo: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "https://{s}/api/v1/repos/{s}/{s}/releases", .{ domain, owner, repo });
    }

    pub fn check_gitea_update(self: UpdateManager, domain: []const u8, owner: []const u8, repo: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        const url = try gitea_to_releases_api(self.allocator, domain, owner, repo);
        defer self.allocator.free(url);

        var client = http_client.HttpClient.init(self.allocator, self.io, "Shelly-AppImage-Manager");
        defer client.deinit();

        const response = client.get(url, &.{
            .{ .name = "Accept", .value = "application/json" },
        }) catch return null;
        defer response.deinit(self.allocator);

        if (response.status != .ok) return null;

        return parse_github_response(self.allocator, response.body, app_name, current_version, allow_prerelease);
    }

    pub fn check_codeberg_update(self: UpdateManager, owner: []const u8, repo: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        return self.check_gitea_update("codeberg.org", owner, repo, app_name, current_version, allow_prerelease);
    }

    pub fn check_forgejo_update(self: UpdateManager, update_url: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        const uri = std.Uri.parse(update_url) catch return null;
        const host = switch (uri.host orelse return null) {
            .raw => |h| h,
            .percent_encoded => |h| h,
        };
        const path = switch (uri.path) {
            .raw => |p| p,
            .percent_encoded => |p| p,
        };
        if (countChar(path, '/') != 2) return null;
        const after_slash = path[1..]; // skip leading '/'
        const sep = std.mem.indexOf(u8, after_slash, "/") orelse return null;
        const owner = after_slash[0..sep];
        const repo = after_slash[sep + 1 ..];
        if (owner.len == 0 or repo.len == 0) return null;
        return self.check_gitea_update(host, owner, repo, app_name, current_version, allow_prerelease);
    }

    pub fn check_github_update(self: UpdateManager, owner: []const u8, repo: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        const url = try github_to_releases_api(self.allocator, owner, repo);
        defer self.allocator.free(url);

        var client = http_client.HttpClient.init(self.allocator, self.io, "Shelly-AppImage-Manager");
        defer client.deinit();

        const response = client.get(url, &.{
            .{ .name = "Accept", .value = "application/vnd.github+json" },
        }) catch return null;
        defer response.deinit(self.allocator);

        if (response.status != .ok) return null;

        return parse_github_response(self.allocator, response.body, app_name, current_version, allow_prerelease);
    }

    fn parse_github_response(allocator: std.mem.Allocator, body: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array or root.array.items.len == 0) return null;

        var release: ?std.json.Value = null;
        for (root.array.items) |r| {
            if (!allow_prerelease) {
                const pre = r.object.get("prerelease") orelse continue;
                if (pre == .bool and pre.bool) continue;
            }
            release = r;
            break;
        }
        const rel = release orelse return null;

        const tag_name_val = rel.object.get("tag_name") orelse return null;
        const latest_version = if (tag_name_val == .string) tag_name_val.string else return null;

        var download_url: ?[]const u8 = null;

        const assets_val = rel.object.get("assets") orelse {
            return appimage.AppImageUpdate{
                .name = try allocator.dupe(u8, app_name),
                .version = try allocator.dupe(u8, latest_version),
                .download_url = try allocator.dupe(u8, ""),
                .is_update_available = try version_unknown_or_dif(current_version, latest_version),
            };
        };

        if (assets_val != .array) return null;

        var appimage_assets: std.ArrayList(std.json.Value) = .empty;
        defer appimage_assets.deinit(allocator);
        for (assets_val.array.items) |asset| {
            const name_val = asset.object.get("name") orelse continue;
            if (name_val != .string) continue;
            if (endsWithIgnoreCase(name_val.string, ".AppImage")) {
                try appimage_assets.append(allocator, asset);
            }
        }

        switch (appimage_assets.items.len) {
            1 => {
                if (appimage_assets.items[0].object.get("browser_download_url")) |url_val| {
                    if (url_val == .string) download_url = url_val.string;
                }
            },
            0 => {},
            else => {
                for (appimage_assets.items) |asset| {
                    const name_val = asset.object.get("name") orelse continue;
                    if (name_val != .string) continue;
                    if (isCorrectArchitecture(name_val.string)) {
                        const url_val = asset.object.get("browser_download_url") orelse continue;
                        if (url_val == .string) {
                            download_url = url_val.string;
                            break;
                        }
                    }
                }
                if (download_url == null) {
                    if (appimage_assets.items[0].object.get("browser_download_url")) |url_val| {
                        if (url_val == .string) download_url = url_val.string;
                    }
                }
            },
        }

        return appimage.AppImageUpdate{
            .name = try allocator.dupe(u8, app_name),
            .version = try allocator.dupe(u8, latest_version),
            .download_url = try allocator.dupe(u8, download_url orelse ""),
            .is_update_available = try version_unknown_or_dif(current_version, latest_version),
        };
    }

    const GitLabProject = struct {
        host: []const u8,
        project_path: []const u8,
        is_shorthand: bool,
    };

    fn parse_gitlab_project(update_info: []const u8) ?GitLabProject {
        if (update_info.len == 0) return null;

        if (std.mem.indexOf(u8, update_info, "://") == null) {
            if (countChar(update_info, '/') != 1 or update_info[0] == '/' or update_info[update_info.len - 1] == '/') return null;
            const idx = std.mem.indexOf(u8, update_info, "/").?;
            if (idx == 0 or idx + 1 >= update_info.len) return null;
            return .{
                .host = "gitlab.com",
                .project_path = update_info,
                .is_shorthand = true,
            };
        }

        const uri = std.Uri.parse(update_info) catch return null;
        if (!std.mem.eql(u8, uri.scheme, "https")) return null;

        const host = switch (uri.host orelse return null) {
            .raw => |h| h,
            .percent_encoded => |h| h,
        };
        if (host.len == 0) return null;

        const path = switch (uri.path) {
            .raw => |p| p,
            .percent_encoded => |p| p,
        };
        if (path.len < 2 or path[0] != '/') return null;
        if (std.mem.startsWith(u8, path, "/api/")) return null;

        const project_path = path[1..];
        if (countChar(project_path, '/') < 1) return null;
        var segments = std.mem.splitScalar(u8, project_path, '/');
        while (segments.next()) |segment| {
            if (segment.len == 0) return null;
        }

        return .{
            .host = host,
            .project_path = project_path,
            .is_shorthand = false,
        };
    }

    pub fn check_gitlab_update(self: UpdateManager, update_info: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        const project = parse_gitlab_project(update_info) orelse return null;
        const url = try gitlab_to_releases_api(self.allocator, project.host, project.project_path);
        defer self.allocator.free(url);

        var client = http_client.HttpClient.init(self.allocator, self.io, "Shelly-AppImage-Manager");
        defer client.deinit();

        const response = client.get(url, &.{
            .{ .name = "Accept", .value = "application/json" },
        }) catch return null;
        defer response.deinit(self.allocator);

        if (response.status != .ok) return null;

        return parse_gitlab_response(self.allocator, response.body, app_name, current_version, allow_prerelease);
    }

    fn github_to_releases_api(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases", .{ owner, repo });
    }

    fn gitlab_to_releases_api(allocator: std.mem.Allocator, host: []const u8, project_path: []const u8) ![]u8 {
        const encoded = try std.mem.replaceOwned(u8, allocator, project_path, "/", "%2F");
        defer allocator.free(encoded);
        return std.fmt.allocPrint(allocator, "https://{s}/api/v4/projects/{s}/releases", .{ host, encoded });
    }

    fn parse_gitlab_response(allocator: std.mem.Allocator, body: []const u8, app_name: []const u8, current_version: []const u8, allow_prerelease: bool) !?appimage.AppImageUpdate {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array or root.array.items.len == 0) return null;

        var release: ?std.json.Value = null;
        for (root.array.items) |r| {
            if (!allow_prerelease) {
                if (r.object.get("upcoming_release")) |upcoming| {
                    if (upcoming == .bool and upcoming.bool) continue;
                }
            }
            release = r;
            break;
        }
        const rel = release orelse return null;

        const tag_name_val = rel.object.get("tag_name") orelse return null;
        const latest_version = if (tag_name_val == .string) tag_name_val.string else return null;

        var download_url: ?[]const u8 = null;

        const assets_val = rel.object.get("assets") orelse {
            return appimage.AppImageUpdate{
                .name = try allocator.dupe(u8, app_name),
                .version = try allocator.dupe(u8, latest_version),
                .download_url = try allocator.dupe(u8, ""),
                .is_update_available = try version_unknown_or_dif(current_version, latest_version),
            };
        };

        const links_val = if (assets_val == .object) assets_val.object.get("links") else null;
        if (links_val == null) {
            return appimage.AppImageUpdate{
                .name = try allocator.dupe(u8, app_name),
                .version = try allocator.dupe(u8, latest_version),
                .download_url = try allocator.dupe(u8, ""),
                .is_update_available = try version_unknown_or_dif(current_version, latest_version),
            };
        }

        const links = links_val.?;
        if (links != .array) return null;

        var appimage_links: std.ArrayList(std.json.Value) = .empty;
        defer appimage_links.deinit(allocator);
        for (links.array.items) |link| {
            const name_val = link.object.get("name") orelse continue;
            if (name_val != .string) continue;
            if (endsWithIgnoreCase(name_val.string, ".AppImage")) {
                try appimage_links.append(allocator, link);
            }
        }

        switch (appimage_links.items.len) {
            1 => {
                if (appimage_links.items[0].object.get("url")) |url_val| {
                    if (url_val == .string) download_url = url_val.string;
                }
            },
            0 => {},
            else => {
                for (appimage_links.items) |link| {
                    const name_val = link.object.get("name") orelse continue;
                    if (name_val != .string) continue;
                    if (isCorrectArchitecture(name_val.string)) {
                        const url_val = link.object.get("url") orelse continue;
                        if (url_val == .string) {
                            download_url = url_val.string;
                            break;
                        }
                    }
                }
                if (download_url == null) {
                    if (appimage_links.items[0].object.get("url")) |url_val| {
                        if (url_val == .string) download_url = url_val.string;
                    }
                }
            },
        }

        return appimage.AppImageUpdate{
            .name = try allocator.dupe(u8, app_name),
            .version = try allocator.dupe(u8, latest_version),
            .download_url = try allocator.dupe(u8, download_url orelse ""),
            .is_update_available = try version_unknown_or_dif(current_version, latest_version),
        };
    }

    fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        const tail = haystack[haystack.len - needle.len ..];
        return std.ascii.eqlIgnoreCase(tail, needle);
    }

    fn is_appimage(file_path: []const u8) !bool {
        const ext = std.fs.path.extension(file_path);
        return std.ascii.eqlIgnoreCase(ext, ".AppImage");
    }

    fn version_unknown_or_dif(current_version: []const u8, last_version: []const u8) !bool {
        if (std.ascii.eqlIgnoreCase(current_version, "Unknown")) {
            return true;
        }

        return !std.ascii.eqlIgnoreCase(current_version, last_version);
    }
};

test "test isAppImage" {
    const result = try UpdateManager.is_appimage("xxx.appImage");
    const result2 = try UpdateManager.is_appimage("xxx.appimage");
    const result3 = try UpdateManager.is_appimage("xxx.ApPiMagE");
    try std.testing.expect(result);
    try std.testing.expect(result2);
    try std.testing.expect(result3);
}

test "test version unknown or diff" {
    const result_true_1 = try UpdateManager.version_unknown_or_dif("67", "Unknown");
    const result_false_1 = try UpdateManager.version_unknown_or_dif("67", "67");
    const result_true_2 = try UpdateManager.version_unknown_or_dif("67", "68");
    try std.testing.expect(result_true_1);
    try std.testing.expect(!result_false_1);
    try std.testing.expect(result_true_2);
}

test "test sysarch assume x86_64" {
    const sys_arch = UpdateManager.getSystemArchitecture();
    try std.testing.expectEqualStrings("x86_64", sys_arch);
}

test "test isCorrectArchitecture - x86_64" {
    const result1 = UpdateManager.isCorrectArchitecture("my-app-x86_64.AppImage");
    try std.testing.expect(result1);
}

test "configureUpdates: None resets url and repo fields" {
    var app = appimage.AppImage{
        .name = "Test",
        .update_type = .github,
        .update_url = "stale",
        .repo_owner = "old-owner",
        .repo_name = "old-repo",
    };

    try UpdateManager.configure_update("ignored", .none, &app, true);

    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
    try std.testing.expectEqualStrings("", app.update_url);
    try std.testing.expectEqual(@as(?[]const u8, null), app.repo_owner);
    try std.testing.expectEqual(@as(?[]const u8, null), app.repo_name);
    try std.testing.expectEqual(true, app.allow_prerelease);
}

test "configureUpdates: StaticUrl stores the url verbatim" {
    var app = appimage.AppImage{ .name = "Test" };

    try UpdateManager.configure_update("https://example.com/update.json", .static_url, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.static_url, app.update_type);
    try std.testing.expectEqualStrings("https://example.com/update.json", app.update_url);
}

test "configureUpdates: Forgejo accepts a well-formed url" {
    var app = appimage.AppImage{ .name = "Test" };

    try UpdateManager.configure_update("https://codeberg.org/user/repo", .forgejo, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.forgejo, app.update_type);
    try std.testing.expectEqualStrings("https://codeberg.org/user/repo", app.update_url);
}

test "configureUpdates: Forgejo rejects a url missing the scheme separator" {
    var app = appimage.AppImage{ .name = "Test", .update_type = .none };

    try UpdateManager.configure_update("codeberg.org/user/repo", .forgejo, &app, false);

    // Parsing failed, so the type should never have been set to .forgejo.
    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
}

test "configureUpdates: Forgejo rejects a url with the wrong path depth" {
    var app = appimage.AppImage{ .name = "Test", .update_type = .none };

    try UpdateManager.configure_update("https://codeberg.org/user/repo/extra", .forgejo, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
}

test "configureUpdates: GitHub/GitLab/Codeberg split owner and repo" {
    var app = appimage.AppImage{ .name = "Test" };

    try UpdateManager.configure_update("torvalds/linux", .github, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.github, app.update_type);
    try std.testing.expectEqualStrings("torvalds", app.repo_owner.?);
    try std.testing.expectEqualStrings("linux", app.repo_name.?);
}

test "configureUpdates: GitLab works identically to GitHub" {
    var app = appimage.AppImage{ .name = "Test" };

    try UpdateManager.configure_update("gitlab-org/gitlab", .gitlab, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.gitlab, app.update_type);
    try std.testing.expectEqualStrings("gitlab-org", app.repo_owner.?);
    try std.testing.expectEqualStrings("gitlab", app.repo_name.?);
}

test "configureUpdates: GitLab full https url stores update_url and clears repo fields" {
    var app = appimage.AppImage{ .name = "Test", .repo_owner = "old", .repo_name = "repo" };

    try UpdateManager.configure_update("https://gitlab.example.com/group/project", .gitlab, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.gitlab, app.update_type);
    try std.testing.expectEqualStrings("https://gitlab.example.com/group/project", app.update_url);
    try std.testing.expectEqual(@as(?[]const u8, null), app.repo_owner);
    try std.testing.expectEqual(@as(?[]const u8, null), app.repo_name);
}

test "configureUpdates: GitLab full https url allows nested groups" {
    var app = appimage.AppImage{ .name = "Test" };

    try UpdateManager.configure_update("https://gitlab.example.com/group/subgroup/project", .gitlab, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.gitlab, app.update_type);
    try std.testing.expectEqualStrings("https://gitlab.example.com/group/subgroup/project", app.update_url);
}

test "configureUpdates: GitLab rejects non-https project urls" {
    var app = appimage.AppImage{ .name = "Test", .update_type = .none };

    try UpdateManager.configure_update("http://gitlab.example.com/group/project", .gitlab, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
}

test "configureUpdates: GitLab rejects api endpoint urls" {
    var app = appimage.AppImage{ .name = "Test", .update_type = .none };

    try UpdateManager.configure_update("https://gitlab.example.com/api/v4/projects/group%2Fproject/releases", .gitlab, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
}

test "configureUpdates: GitLab rejects empty path segments" {
    var app = appimage.AppImage{ .name = "Test", .update_type = .none };

    try UpdateManager.configure_update("https://gitlab.example.com/group//project", .gitlab, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
}

test "configureUpdates: Codeberg rejects malformed owner/repo (no slash)" {
    var app = appimage.AppImage{ .name = "Test", .repo_owner = null, .repo_name = null, .update_type = .none };

    try UpdateManager.configure_update("just-a-name", .codeberg, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
    try std.testing.expectEqual(@as(?[]const u8, null), app.repo_owner);
    try std.testing.expectEqual(@as(?[]const u8, null), app.repo_name);
}

test "configureUpdates: GitHub rejects malformed owner/repo (too many slashes)" {
    var app = appimage.AppImage{ .name = "Test", .update_type = .none };

    try UpdateManager.configure_update("owner/repo/extra", .github, &app, false);

    try std.testing.expectEqual(appimage.UpdateType.none, app.update_type);
}

test "configureUpdates: allow_prerelease is always applied, even on failure paths" {
    var app = appimage.AppImage{ .name = "Test" };

    try UpdateManager.configure_update("malformed", .github, &app, true);

    try std.testing.expectEqual(true, app.allow_prerelease);
}

test "github_to_releases_api builds correct url" {
    const url = try UpdateManager.github_to_releases_api(std.testing.allocator, "ppy", "osu");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.github.com/repos/ppy/osu/releases", url);
}

test "gitlab_to_releases_api builds correct url with encoded path" {
    const url = try UpdateManager.gitlab_to_releases_api(std.testing.allocator, "gitlab.com", "gitlab-org/gitlab");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://gitlab.com/api/v4/projects/gitlab-org%2Fgitlab/releases", url);
}

test "gitlab_to_releases_api builds self-hosted url with encoded nested path" {
    const url = try UpdateManager.gitlab_to_releases_api(std.testing.allocator, "gitlab.example.com", "group/subgroup/project");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://gitlab.example.com/api/v4/projects/group%2Fsubgroup%2Fproject/releases", url);
}

test "parse_github_response: returns null for empty array" {
    const body = "[]";
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "parse_github_response: returns null for invalid json" {
    const body = "not json";
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "parse_github_response: skips prerelease when allow_prerelease=false" {
    const body =
        \\[
        \\  {"tag_name":"2025.701.0","prerelease":true,"assets":[]},
        \\  {"tag_name":"2025.630.0","prerelease":false,"assets":[]}
        \\]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2025.630.0", result.?.version);
}

test "parse_github_response: includes prerelease when allow_prerelease=true" {
    const body =
        \\[
        \\  {"tag_name":"2025.701.0","prerelease":true,"assets":[]},
        \\  {"tag_name":"2025.630.0","prerelease":false,"assets":[]}
        \\]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", true);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2025.701.0", result.?.version);
}

test "parse_github_response: picks single AppImage asset (ppy/osu style)" {
    const body =
        \\[{
        \\  "tag_name": "2025.630.0",
        \\  "prerelease": false,
        \\  "assets": [
        \\    {"name":"osu.AppImage","browser_download_url":"https://github.com/ppy/osu/releases/download/2025.630.0/osu.AppImage"},
        \\    {"name":"osu.dmg","browser_download_url":"https://github.com/ppy/osu/releases/download/2025.630.0/osu.dmg"}
        \\  ]
        \\}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("osu", result.?.name);
    try std.testing.expectEqualStrings("2025.630.0", result.?.version);
    try std.testing.expectEqualStrings("https://github.com/ppy/osu/releases/download/2025.630.0/osu.AppImage", result.?.download_url);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_github_response: picks arch-matching asset when multiple AppImages present" {
    const body =
        \\[{
        \\  "tag_name": "2025.630.0",
        \\  "prerelease": false,
        \\  "assets": [
        \\    {"name":"osu-aarch64.AppImage","browser_download_url":"https://example.com/osu-aarch64.AppImage"},
        \\    {"name":"osu-x86_64.AppImage","browser_download_url":"https://example.com/osu-x86_64.AppImage"}
        \\  ]
        \\}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("https://example.com/osu-x86_64.AppImage", result.?.download_url);
}

test "parse_github_response: is_update_available false when version matches" {
    const body =
        \\[{"tag_name":"2025.630.0","prerelease":false,"assets":[]}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "2025.630.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_update_available);
}

test "parse_github_response: no assets key returns dto with empty download_url" {
    const body =
        \\[{"tag_name":"2025.630.0","prerelease":false}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "osu", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?.download_url);
}

test "parse_gitlab_response: returns null for empty array" {
    const body = "[]";
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    try std.testing.expectEqual(@as(?appimage.AppImageUpdate, null), result);
}

test "parse_gitlab_response: skips upcoming_release when allow_prerelease=false" {
    const body =
        \\[
        \\  {"tag_name":"v2.0.0","upcoming_release":true,"assets":{"links":[]}},
        \\  {"tag_name":"v1.9.0","upcoming_release":false,"assets":{"links":[]}}
        \\]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("v1.9.0", result.?.version);
}

test "parse_gitlab_response: includes upcoming_release when allow_prerelease=true" {
    const body =
        \\[
        \\  {"tag_name":"v2.0.0","upcoming_release":true,"assets":{"links":[]}},
        \\  {"tag_name":"v1.9.0","upcoming_release":false,"assets":{"links":[]}}
        \\]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", true);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("v2.0.0", result.?.version);
}

test "parse_gitlab_response: picks single AppImage link" {
    const body =
        \\[{
        \\  "tag_name": "v1.9.0",
        \\  "upcoming_release": false,
        \\  "assets": {
        \\    "links": [
        \\      {"name":"myapp-x86_64.AppImage","url":"https://gitlab.com/mygroup/myapp/-/releases/v1.9.0/downloads/myapp-x86_64.AppImage"},
        \\      {"name":"myapp.tar.gz","url":"https://gitlab.com/mygroup/myapp/-/releases/v1.9.0/downloads/myapp.tar.gz"}
        \\    ]
        \\  }
        \\}]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("myapp", result.?.name);
    try std.testing.expectEqualStrings("v1.9.0", result.?.version);
    try std.testing.expectEqualStrings("https://gitlab.com/mygroup/myapp/-/releases/v1.9.0/downloads/myapp-x86_64.AppImage", result.?.download_url);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_gitlab_response: no assets key returns dto with empty download_url" {
    const body =
        \\[{"tag_name":"v1.9.0","upcoming_release":false}]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?.download_url);
}

test "gitea_to_releases_api builds correct url" {
    const url = try UpdateManager.gitea_to_releases_api(std.testing.allocator, "codeberg.org", "user", "myapp");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://codeberg.org/api/v1/repos/user/myapp/releases", url);
}

test "gitea_to_releases_api builds correct url for custom forgejo domain" {
    const url = try UpdateManager.gitea_to_releases_api(std.testing.allocator, "git.example.com", "alice", "tool");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://git.example.com/api/v1/repos/alice/tool/releases", url);
}

test "parse_github_response: codeberg/forgejo style response (same shape as github)" {
    const body =
        \\[{
        \\  "tag_name": "v1.2.3",
        \\  "prerelease": false,
        \\  "assets": [
        \\    {"name":"myapp-x86_64.AppImage","browser_download_url":"https://codeberg.org/user/myapp/releases/download/v1.2.3/myapp-x86_64.AppImage"}
        \\  ]
        \\}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("myapp", result.?.name);
    try std.testing.expectEqualStrings("v1.2.3", result.?.version);
    try std.testing.expectEqualStrings("https://codeberg.org/user/myapp/releases/download/v1.2.3/myapp-x86_64.AppImage", result.?.download_url);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_github_response: forgejo skips prerelease when allow_prerelease=false" {
    const body =
        \\[
        \\  {"tag_name":"v2.0.0-beta","prerelease":true,"assets":[]},
        \\  {"tag_name":"v1.9.0","prerelease":false,"assets":[]}
        \\]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("v1.9.0", result.?.version);
}

test "parse_github_response: forgejo includes prerelease when allow_prerelease=true" {
    const body =
        \\[
        \\  {"tag_name":"v2.0.0-beta","prerelease":true,"assets":[]},
        \\  {"tag_name":"v1.9.0","prerelease":false,"assets":[]}
        \\]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "myapp", "0.0.0", true);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("v2.0.0-beta", result.?.version);
}

test "build_static_url: uses etag as version and strips quotes" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "0.0.0", "\"abc123\"");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("myapp", result.?.name);
    try std.testing.expectEqualStrings("abc123", result.?.version);
    try std.testing.expectEqualStrings("https://example.com/myapp.AppImage", result.?.download_url);
    try std.testing.expect(result.?.is_update_available);
}

test "build_static_url: uses last-modified as version when no etag quotes" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "0.0.0", "Mon, 01 Jan 2025 00:00:00 GMT");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Mon, 01 Jan 2025 00:00:00 GMT", result.?.version);
    try std.testing.expectEqualStrings("https://example.com/myapp.AppImage", result.?.download_url);
    try std.testing.expect(result.?.is_update_available);
}

test "build_static_url: is_update_available false when version matches etag" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "abc123", "\"abc123\"");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_update_available);
}

test "build_static_url: empty raw_version yields empty version string and update available" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "1.0.0", "");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?.version);
    try std.testing.expect(result.?.is_update_available);
}

test "build_static_url: current version Unknown always reports update available" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "myapp", "https://example.com/myapp.AppImage", "Unknown", "\"abc123\"");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_gitlab_response: no links key returns dto with empty download_url" {
    const body =
        \\[{"tag_name":"v1.9.0","upcoming_release":false,"assets":{}}]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "0.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?.download_url);
}

test "build_static_url: name is preserved in result" {
    const result = try UpdateManager.build_static_url(std.testing.allocator, "my-special-app", "https://example.com/app.AppImage", "0.0.0", "\"v2.0\"");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("my-special-app", result.?.name);
    try std.testing.expectEqualStrings("v2.0", result.?.version);
    try std.testing.expect(result.?.is_update_available);
}

test "build_static_url: download_url is preserved verbatim" {
    const url = "https://releases.example.com/path/to/app-x86_64.AppImage";
    const result = try UpdateManager.build_static_url(std.testing.allocator, "app", url, "0.0.0", "etag-val");
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(url, result.?.download_url);
}

test "parse_github_response: is_update_available true when current is Unknown" {
    const body =
        \\[{"tag_name":"v1.0.0","prerelease":false,"assets":[]}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "myapp", "Unknown", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_github_response: is_update_available false when versions match" {
    const body =
        \\[{"tag_name":"v1.0.0","prerelease":false,"assets":[]}]
    ;
    const result = try UpdateManager.parse_github_response(std.testing.allocator, body, "myapp", "v1.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_update_available);
}

test "parse_gitlab_response: is_update_available true when current is Unknown" {
    const body =
        \\[{"tag_name":"v3.0.0","upcoming_release":false,"assets":{"links":[]}}]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "Unknown", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.is_update_available);
}

test "parse_gitlab_response: is_update_available false when versions match" {
    const body =
        \\[{"tag_name":"v3.0.0","upcoming_release":false,"assets":{"links":[]}}]
    ;
    const result = try UpdateManager.parse_gitlab_response(std.testing.allocator, body, "myapp", "v3.0.0", false);
    defer if (result) |r| r.deinit(std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.is_update_available);
}

test "github_to_releases_api: owner and repo are embedded correctly" {
    const url = try UpdateManager.github_to_releases_api(std.testing.allocator, "my-org", "my-repo");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.github.com/repos/my-org/my-repo/releases", url);
}

test "gitlab_to_releases_api: slash in owner/repo is percent-encoded" {
    const url = try UpdateManager.gitlab_to_releases_api(std.testing.allocator, "gitlab.com", "my-group/my-project");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "%2F") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "my-group") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "my-project") != null);
}

fn makeUpdateManager(allocator: std.mem.Allocator, install_dir: []const u8, db_path: []const u8) UpdateManager {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = install_dir,
        .local_db_path = db_path,
    };
}

fn seedDb(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, apps: []const appimage.AppImage) !void {
    const json_bytes = try std.json.Stringify.valueAlloc(allocator, apps, .{ .whitespace = .indent_2 });
    defer allocator.free(json_bytes);
    var file = try std.Io.Dir.cwd().createFile(io, db_path, .{});
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(json_bytes);
    try writer.interface.flush();
}

test "update: returns false when app not found in db" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{});

    const um = makeUpdateManager(std.testing.allocator, dir_path, db_path);
    var dto = appimage.AppImageUpdate{
        .name = "nonexistent",
        .version = "v2.0",
        .download_url = "https://example.com/app.AppImage",
        .is_update_available = true,
    };
    const result = try um.update(&dto);
    try std.testing.expect(!result);
}

test "update: returns false when download_url is empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = "myapp", .version = "v1.0" },
    });

    const um = makeUpdateManager(std.testing.allocator, dir_path, db_path);
    var dto = appimage.AppImageUpdate{
        .name = "myapp",
        .version = "v2.0",
        .download_url = "",
        .is_update_available = true,
    };
    const result = try um.update(&dto);
    try std.testing.expect(!result);
}

test "update: returns false when current AppImage file does not exist on disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = "myapp", .version = "v1.0" },
    });

    // intentionally do NOT create myapp.AppImage in dir_path
    const um = makeUpdateManager(std.testing.allocator, dir_path, db_path);
    var dto = appimage.AppImageUpdate{
        .name = "myapp",
        .version = "v2.0",
        .download_url = "https://example.com/myapp.AppImage",
        .is_update_available = true,
    };
    const result = try um.update(&dto);
    try std.testing.expect(!result);
}

test "update: downloads real AppImage and returns true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    const app_name = "appimagetool";
    const download_url = "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage";

    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = app_name, .version = "v0.0", .desktop_name = app_name },
    });

    // Create a placeholder current AppImage so the file-exists guard passes
    const current_filename = try std.fmt.allocPrint(std.testing.allocator, "{s}.AppImage", .{app_name});
    defer std.testing.allocator.free(current_filename);
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, current_filename });
    defer std.testing.allocator.free(current_path);
    {
        var f = try std.Io.Dir.cwd().createFile(std.testing.io, current_path, .{});
        f.close(std.testing.io);
    }

    const um = makeUpdateManager(std.testing.allocator, dir_path, db_path);
    var dto = appimage.AppImageUpdate{
        .name = app_name,
        .version = "continuous",
        .download_url = download_url,
        .is_update_available = true,
    };
    const result = try um.update(&dto);
    try std.testing.expect(result);

    // Verify the DB was updated with the new version
    const manager = appimage_manager.AppImageManager{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = std.testing.environ,
        .install_directory = dir_path,
        .local_db_path = db_path,
    };
    const apps = try manager.getAppImagesFromLocalDb();
    defer manager.freeAppImages(apps);
    var found = false;
    for (apps) |a| {
        if (std.mem.eql(u8, a.version, "continuous")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "update: name lookup is case-insensitive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.testing.allocator.dupe(u8, path_buf[0..len]);
    defer std.testing.allocator.free(dir_path);

    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "apps.db" });
    defer std.testing.allocator.free(db_path);

    // DB has "MyApp" but dto uses "myapp" — should still find it, then fail on missing file
    try seedDb(std.testing.allocator, std.testing.io, db_path, &.{
        .{ .name = "MyApp", .version = "v1.0" },
    });

    const um = makeUpdateManager(std.testing.allocator, dir_path, db_path);
    var dto = appimage.AppImageUpdate{
        .name = "myapp",
        .version = "v2.0",
        .download_url = "https://example.com/myapp.AppImage",
        .is_update_available = true,
    };
    // Will fail at "file not found" (not "app not found"), proving case-insensitive match worked
    const result = try um.update(&dto);
    try std.testing.expect(!result);
}
