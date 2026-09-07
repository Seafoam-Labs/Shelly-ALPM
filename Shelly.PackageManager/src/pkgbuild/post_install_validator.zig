const std = @import("std");
const pkgbuild = @import("pkgbuild_parser.zig");
const shared_validator = @import("shared_validtor.zig");

pub const PostInstallValidator = struct {
    allocator: std.mem.Allocator,

    const risky_tools = [_][]const u8{
        // JavaScript / Node
        "npm",    "npx",        "yarn",          "pnpm",          "pnpx",     "bun",            "node",   "deno",
        // Python
        "pip",    "pip3",       "pipx",          "uv",            "poetry",   "pipenv",         "rye",    "conda",
        "mamba",  "micromamba",
        // Ruby
        "gem",
        // Rust
                  "cargo install", "rustup",
        // Go
          "go install",
        // PHP
            "php",    "composer",
        // Perl
        "cpan",   "cpanm",
        // Haskell
             "cabal install", "stack install",
        // Lua
        "luarocks",
        // Nim
        "nimble install",
        // OCaml
        "opam",
        // Elixir / Erlang
          "mix",
        "rebar3",
        // C/C++
        "conan",      "vcpkg",
        // JVM / Scala / Clojure
                "gradle",        "mvn",      "sbt",            "ant",    "lein",
        // .NET
        "dotnet",
        // Swift
        "swift",
        // Julia
             "julia",
        // R
                "Rscript",
        // Downloaders / network tools
              "curl",     "wget",           "wget2",  "aria2c",
        "lftp",   "rsync",      "scp",           "sftp",          "fetch",
        // Containers / orchestration / alternative package managers
           "docker",         "podman", "kubectl",
        "helm",   "snap",       "flatpak",       "appimage",
        // Version managers
             "nvm",      "rvm",            "rbenv",  "pyenv",
        "gvm",    "asdf",
    };

    const privilege_escalation_tools = [_][]const u8{
        "sudo", "sudoedit", "doas", "pkexec", "run0", "su",
    };

    // PKGBUILD functions whose bodies are scanned in addition to the install
    // scriptlet and local sources. `package_<name>` split-package overrides are
    // covered by scanning the raw PKGBUILD for every `*()` function body.
    const pkgbuild_functions = [_][]const u8{
        "prepare", "pkgver", "build", "check", "package",
    };

    pub fn validate(self: PostInstallValidator, pkg_build: pkgbuild.Pkgbuild) !shared_validator.ValidationResult {
        return self.validateWithContent(pkg_build, null);
    }

    pub fn validateWithContent(self: PostInstallValidator, pkg_build: pkgbuild.Pkgbuild, content: ?[]const u8) !shared_validator.ValidationResult {
        var result = shared_validator.ValidationResult{
            .has_findings = false,
            .findings = std.ArrayList(shared_validator.ValidationFinding).empty,
        };

        if (content) |raw| {
            for (pkgbuild_functions) |function_name| {
                const body = try pkgbuild.PkgbuildParser.extract_function_body(raw, function_name);
                try self.scan_hook(body, function_name, &result);
            }
        }

        var iter = pkg_build.local_source_contents.iterator();
        while (iter.next()) |entry| {
            const hook = try std.fmt.allocPrint(self.allocator, "source: {s}", .{entry.key_ptr.*});
            defer self.allocator.free(hook);
            try self.scan_hook(entry.value_ptr.*, hook, &result);
        }

        return result;
    }

    pub fn scan_hook(self: PostInstallValidator, scriptlet: ?[]const u8, hook: []const u8, result: *shared_validator.ValidationResult) !void {
        const content = scriptlet orelse return;
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            var local_line = strip_shell_comment(line);
            local_line = std.mem.trim(u8, local_line, " \t");
            if (local_line.len == 0) continue;

            const probe = try self.normalize_for_matching(local_line);
            defer self.allocator.free(probe);

            for (risky_tools) |tool| {
                if (!matches_tool_boundary(probe, tool)) continue;
                const was_obfuscated = !matches_tool_boundary(line, tool);
                const message = if (was_obfuscated)
                    try std.fmt.allocPrint(
                        self.allocator,
                        "'{s}' is invoked in {s}() via obfuscated shell syntax — the tool name was deliberately hidden, which is a strong sign of malicious intent.",
                        .{ tool, hook },
                    )
                else
                    try std.fmt.allocPrint(
                        self.allocator,
                        "'{s}' is invoked in {s}() — this fetches/executes external code outside Shelly's control.",
                        .{ tool, hook },
                    );
                const dup_hook = try self.allocator.dupe(u8, hook);
                const dup_line = try self.allocator.dupe(u8, line);
                try result.findings.append(self.allocator, shared_validator.ValidationFinding{
                    .tool = tool,
                    .hook = dup_hook,
                    .severity = if (was_obfuscated) .critical else .warning,
                    .matched_line = dup_line,
                    .message = message,
                });
                result.has_findings = true;
            }

            for (privilege_escalation_tools) |tool| {
                if (!matches_tool_boundary(probe, tool)) continue;
                const was_obfuscated = !matches_tool_boundary(line, tool);
                const message = if (was_obfuscated)
                    try std.fmt.allocPrint(
                        self.allocator,
                        "Privilege escalation tool '{s}' is invoked in {s}() via obfuscated shell syntax - the tool name was deliberately hidden, which is a strong sign of malicious intent.",
                        .{ tool, hook },
                    )
                else
                    try std.fmt.allocPrint(
                        self.allocator,
                        "Privilege escalation tool '{s}' is invoked in {s}() - this runs code as root outside of shelly and libalpm's control and can give the package unrestricted access to the whole system.",
                        .{ tool, hook },
                    );
                const dup_hook = try self.allocator.dupe(u8, hook);
                const dup_line = try self.allocator.dupe(u8, line);
                try result.findings.append(self.allocator, shared_validator.ValidationFinding{
                    .tool = tool,
                    .hook = dup_hook,
                    .severity = .critical,
                    .matched_line = dup_line,
                    .message = message,
                });
                result.has_findings = true;
            }

            try self.scan_dynamic_execution(local_line, hook, result);
        }
    }

    fn matches_tool_boundary(text: []const u8, tool: []const u8) bool {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, text, start, tool)) |idx| {
            const prev_ok = idx == 0 or is_boundary_before_eval(text[idx - 1]);
            const after_idx = idx + tool.len;
            const next_ok = after_idx == text.len or std.ascii.isWhitespace(text[after_idx]);
            if (prev_ok and next_ok) return true;
            start = idx + 1;
        }
        return false;
    }

    fn has_eval_token(line: []const u8) bool {
        const needle = "eval";
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, line, start, needle)) |idx| {
            const prev_ok = idx == 0 or is_boundary_before_eval(line[idx - 1]);
            const after_idx = idx + needle.len;
            const next_ok = after_idx == line.len or std.ascii.isWhitespace(line[after_idx]);
            if (prev_ok and next_ok) return true;
            start = idx + 1;
        }
        return false;
    }

    fn is_boundary_before_eval(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\n', '\r', 0x0B, 0x0C, ';', '&', '|', '`', '(' => true,
            else => false,
        };
    }

    fn has_encode_pipe_shell(line: []const u8) bool {
        const commands = [_][]const u8{ "base64", "xxd", "printf", "echo" };
        inline for (commands) |cmd| {
            var start: usize = 0;
            while (std.mem.indexOfPos(u8, line, start, cmd)) |idx| {
                const after_cmd = idx + cmd.len;
                const boundary_ok = after_cmd == line.len or !is_word(line[after_cmd]);
                if (boundary_ok) {
                    if (std.mem.indexOfScalarPos(u8, line, after_cmd, '|')) |pipe_idx| {
                        var j = pipe_idx + 1;
                        while (j < line.len and std.ascii.isWhitespace(line[j])) : (j += 1) {}
                        if (matches_shell_word(line, j)) return true;
                    }
                }
                start = idx + 1;
            }
        }
        return false;
    }

    fn matches_shell_word(line: []const u8, pos: usize) bool {
        const shells = [_][]const u8{ "sh", "bash", "zsh" };
        inline for (shells) |shell| {
            if (pos + shell.len <= line.len and
                std.mem.eql(u8, line[pos .. pos + shell.len], shell))
            {
                const after = pos + shell.len;
                if (after == line.len or !is_word(line[after])) return true;
            }
        }
        return false;
    }

    fn contains_command_substitution(line: []const u8) bool {
        return std.mem.indexOf(u8, line, "$(") != null or
            std.mem.indexOfScalar(u8, line, '`') != null;
    }

    fn contains_variable_indirection(line: []const u8) bool {
        return std.mem.indexOf(u8, line, "${!") != null;
    }

    pub fn scan_dynamic_execution(self: PostInstallValidator, line: []const u8, hook: []const u8, result: *shared_validator.ValidationResult) !void {
        const is_eval_into_shell = has_eval_token(line) or has_encode_pipe_shell(line);
        const has_command_substitution = contains_command_substitution(line);
        const has_variable_indirection = contains_variable_indirection(line);

        if (!is_eval_into_shell and !has_command_substitution and !has_variable_indirection)
            return;

        const message = if (is_eval_into_shell)
            try std.fmt.allocPrint(
                self.allocator,
                "Dynamic command execution detected in {s}() — a command is decoded/evaluated and run at install time, so its real behavior cannot be reviewed.",
                .{hook},
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "Dynamic command construction detected in {s}() — the effective command is computed at runtime and cannot be statically resolved.",
                .{hook},
            );

        const dup_hook = try self.allocator.dupe(u8, hook);
        const dup_line = try self.allocator.dupe(u8, line);
        try result.findings.append(self.allocator, shared_validator.ValidationFinding{
            .tool = "<dynamic-command>",
            .hook = dup_hook,
            .severity = if (is_eval_into_shell) .critical else .warning,
            .matched_line = dup_line,
            .message = message,
        });
        result.has_findings = true;
    }

    fn strip_shell_comment(line: []const u8) []const u8 {
        var in_single_q = false;
        var in_double_q = false;
        for (line, 0..) |char, i| {
            if (char == '"' and !in_single_q) in_double_q = !in_double_q else if (char == '\'' and !in_double_q) in_single_q = !in_single_q else if (char == '#' and !in_single_q and !in_double_q) return line[0..i];
        }
        return line;
    }

    fn normalize_for_matching(self: PostInstallValidator, line: []const u8) ![]const u8 {
        var sb: std.ArrayList(u8) = .empty;
        errdefer sb.deinit(self.allocator);

        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const char = line[i];

            if (char == '\\' and i + 1 < line.len) {
                const next = line[i + 1];
                if (next != '\\' and !std.ascii.isWhitespace(next))
                    continue;
            }

            if (char == '\'' or char == '"') {
                const prev_is_word = sb.items.len > 0 and is_word(sb.items[sb.items.len - 1]);
                var j = i;
                while (j < line.len and (line[j] == '\'' or line[j] == '"')) : (j += 1) {}
                const next_is_word = j < line.len and is_word(line[j]);
                if (prev_is_word or next_is_word) {
                    i = j - 1;
                    continue;
                }
            }

            try sb.append(self.allocator, char);
        }

        return sb.toOwnedSlice(self.allocator);
    }

    fn is_word(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};

test "no comment returns full line" {
    try std.testing.expectEqualStrings("hello world", PostInstallValidator.strip_shell_comment("hello world"));
}

test "simple trailing comment is stripped" {
    try std.testing.expectEqualStrings("echo hi ", PostInstallValidator.strip_shell_comment("echo hi # comment"));
}

test "comment at start strips everything" {
    try std.testing.expectEqualStrings("", PostInstallValidator.strip_shell_comment("# just a comment"));
}

test "hash inside double quotes is not a comment" {
    try std.testing.expectEqualStrings("echo \"a#b\"", PostInstallValidator.strip_shell_comment("echo \"a#b\""));
}

test "hash inside single quotes is not a comment" {
    try std.testing.expectEqualStrings("echo 'a#b'", PostInstallValidator.strip_shell_comment("echo 'a#b'"));
}

test "hash after quotes close is a comment" {
    try std.testing.expectEqualStrings("echo \"quoted\" ", PostInstallValidator.strip_shell_comment("echo \"quoted\" # trailing"));
}

test "single quote inside double quotes is literal" {
    try std.testing.expectEqualStrings("echo \"it's fine\"", PostInstallValidator.strip_shell_comment("echo \"it's fine\""));
}

test "double quote inside single quotes is literal" {
    try std.testing.expectEqualStrings("echo 'say \"hi\"'", PostInstallValidator.strip_shell_comment("echo 'say \"hi\"'"));
}

test "unterminated quote suppresses comment to end of line" {
    // Once in_double_q is true and never closed, the trailing # is inside quotes
    try std.testing.expectEqualStrings("echo \"unterminated # not a comment", PostInstallValidator.strip_shell_comment("echo \"unterminated # not a comment"));
}

test "plain line with no special chars is unchanged" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    const out = try validator.normalize_for_matching("hello world");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}

test "backslash escaping a word char is dropped" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    const out = try validator.normalize_for_matching("fo\\o");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("foo", out);
}

test "backslash before whitespace is preserved (line continuation)" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    const out = try validator.normalize_for_matching("foo\\ bar");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("foo\\ bar", out);
}

test "backslash before backslash is preserved, next one is consumed" {
    // input chars: a \ \ b
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    const out = try validator.normalize_for_matching("a\\\\b");
    defer std.testing.allocator.free(out);
    // first backslash kept (escapes nothing since next is '\\'),
    // second backslash dropped (escapes 'b')
    try std.testing.expectEqualStrings("a\\b", out);
}

test "split quotes around a word are stripped: b''u''n -> bun" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    const out = try validator.normalize_for_matching("b''u''n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("bun", out);
}

test "split quotes with double quotes: n\"p\"m -> npm" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    const out = try validator.normalize_for_matching("n\"p\"m");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("npm", out);
}

test "quotes touching only one side (start of word) are still stripped" {
    // prevIsWord is false here, but nextIsWord is true, and the check is OR,
    // so the leading quote is dropped too.
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    const out = try validator.normalize_for_matching("'hello'");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "quotes surrounded by whitespace are preserved" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    const out = try validator.normalize_for_matching("a ' ' b");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a ' ' b", out);
}

test "empty string" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    const out = try validator.normalize_for_matching("");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

fn empty_result() shared_validator.ValidationResult {
    return .{
        .has_findings = false,
        .findings = std.ArrayList(shared_validator.ValidationFinding).empty,
    };
}

test "bare eval at start of line is critical" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_dynamic_execution("eval \"$cmd\"", "postInstall", &result);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "eval as a substring inside another word is not flagged" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_dynamic_execution("myeval value", "postInstall", &result);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
    try std.testing.expect(!result.has_findings);
}

test "eval preceded by pipe and at end of line is critical (matches C# leniency)" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_dynamic_execution("cat file | grep eval", "postInstall", &result);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "echo piped into bash is critical" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_dynamic_execution("echo $encoded | bash", "postInstall", &result);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "base64 decode piped into sh is critical" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_dynamic_execution("base64 -d file.txt | sh -c -", "postInstall", &result);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "echo without a pipe is not flagged" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_dynamic_execution("echo hello world", "postInstall", &result);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
    try std.testing.expect(!result.has_findings);
}

test "command substitution with $() is a warning" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_dynamic_execution("VAR=$(hostname)", "postInstall", &result);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.warning, result.findings.items[0].severity);
}

test "command substitution with backticks is a warning" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_dynamic_execution("echo `whoami`", "postInstall", &result);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.warning, result.findings.items[0].severity);
}

test "bash indirect variable expansion is a warning" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_dynamic_execution("cmd=${!name}; $cmd", "postInstall", &result);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.warning, result.findings.items[0].severity);
}

test "ordinary parameter expansion is benign and not flagged" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_dynamic_execution("echo ${HOME}/bin", "postInstall", &result);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
    try std.testing.expect(!result.has_findings);
}

test "scan_hook returns immediately for a null scriptlet" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_hook(null, "post_install", &result);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
    try std.testing.expect(!result.has_findings);
}

test "scan_hook finds nothing in a benign multi-line scriptlet" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    const scriptlet =
        \\echo "installing package"
        \\mkdir -p /opt/myapp
        \\chmod +x /opt/myapp/run.sh
    ;
    try validator.scan_hook(scriptlet, "post_install", &result);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
    try std.testing.expect(!result.has_findings);
}

test "scan_hook skips blank and comment-only lines without crashing" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    const scriptlet =
        \\
        \\
        \\# just a comment, nothing to see here
        \\true
    ;
    try validator.scan_hook(scriptlet, "post_install", &result);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
    try std.testing.expect(!result.has_findings);
}

test "a risky tool mentioned only in a trailing comment is not flagged" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_hook("true # curl is not actually run here", "post_install", &result);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
    try std.testing.expect(!result.has_findings);
}

test "a plainly invoked risky tool is a warning" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_hook("curl https://example.com/install.sh -o installer.sh", "post_install", &result);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqualStrings("curl", result.findings.items[0].tool);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.warning, result.findings.items[0].severity);
}

test "a quote-obfuscated risky tool is critical" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_hook("c''u''r''l https://example.com/install.sh", "post_install", &result);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqualStrings("curl", result.findings.items[0].tool);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "multiple risky tools on one line each produce their own finding" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);

    try validator.scan_hook("npm install && curl https://example.com/x", "post_install", &result);

    try std.testing.expectEqual(@as(usize, 2), result.findings.items.len);
    try std.testing.expect(result.has_findings);
}

test "scan_hook delegates to scan_dynamic_execution for eval-only lines" {
    const validator = PostInstallValidator{ .allocator = std.testing.allocator };
    var result = empty_result();
    defer result.deinit(std.testing.allocator);
    try validator.scan_hook("eval $(cat payload.b64 | base64 -d)", "post_install", &result);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

fn make_test_pkgbuild(
    allocator: std.mem.Allocator,
    script_contents: ?[]const u8,
) !pkgbuild.Pkgbuild {
    var lsc = std.StringHashMap([]const u8).init(allocator);
    if (script_contents) |contents| {
        const key = try allocator.dupe(u8, "__test.install");
        errdefer allocator.free(key);
        try lsc.put(key, contents);
    }
    return pkgbuild.Pkgbuild{
        .variables = std.StringHashMap([]const u8).init(allocator),
        .local_source_contents = lsc,
    };
}

fn deinit_test_pkgbuild(pkg: *pkgbuild.Pkgbuild, allocator: std.mem.Allocator) void {
    var lsc_it = pkg.local_source_contents.iterator();
    while (lsc_it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    pkg.local_source_contents.deinit();

    var var_it = pkg.variables.iterator();
    while (var_it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    pkg.variables.deinit();
}

test "validate: empty pkgbuild produces no findings" {
    const allocator = std.testing.allocator;
    var pkg = try make_test_pkgbuild(allocator, null);
    defer deinit_test_pkgbuild(&pkg, allocator);

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
    try std.testing.expect(!result.has_findings);
}

test "validate: benign post_install produces no findings" {
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8,
        \\echo "installing package"
        \\mkdir -p /opt/myapp
        \\chmod +x /opt/myapp/run.sh
    );
    var pkg = try make_test_pkgbuild(allocator, script);
    defer {
        deinit_test_pkgbuild(&pkg, allocator);
    }

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
    try std.testing.expect(!result.has_findings);
}

test "validate: risky tool in post_install produces warning finding" {
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8, "curl https://example.com/install.sh -o installer.sh");
    var pkg = try make_test_pkgbuild(allocator, script);
    defer {
        deinit_test_pkgbuild(&pkg, allocator);
    }

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqualStrings("curl", result.findings.items[0].tool);
    try std.testing.expectEqualStrings("source: __test.install", result.findings.items[0].hook);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.warning, result.findings.items[0].severity);
}

test "validate: eval in post_install produces critical finding" {
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8, "eval \"$(cat payload.b64 | base64 -d)\"");
    var pkg = try make_test_pkgbuild(allocator, script);
    defer {
        deinit_test_pkgbuild(&pkg, allocator);
    }

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "validate: obfuscated tool in post_install is critical" {
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8, "c''u''r''l https://example.com/install.sh");
    var pkg = try make_test_pkgbuild(allocator, script);
    defer {
        deinit_test_pkgbuild(&pkg, allocator);
    }

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqualStrings("curl", result.findings.items[0].tool);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "validate: sudo in post_install produces critical finding" {
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8, "sudo systemctl enable miner.service");
    var pkg = try make_test_pkgbuild(allocator, script);
    defer deinit_test_pkgbuild(&pkg, allocator);

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expectEqualStrings("sudo", result.findings.items[0].tool);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "validate: doas pkexec run0 and su in post_install are critical" {
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8,
        \\doas tee /etc/cron.d/payload
        \\pkexec /usr/share/demo/helper
        \\run0 /bin/sh
        \\su -c 'id'
    );
    var pkg = try make_test_pkgbuild(allocator, script);
    defer deinit_test_pkgbuild(&pkg, allocator);

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.findings.items.len);
    for (result.findings.items) |finding|
        try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, finding.severity);
}

test "validate: words containing sudo are not flagged" {
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8,
        \\echo "sudoku is a game, pseudo is a prefix"
        \\install -m644 sushell.desktop /usr/share/applications/
    );
    var pkg = try make_test_pkgbuild(allocator, script);
    defer deinit_test_pkgbuild(&pkg, allocator);

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
}

test "validate: sudo in local source file is critical" {
    const allocator = std.testing.allocator;
    var pkg = try make_test_pkgbuild(allocator, null);
    defer deinit_test_pkgbuild(&pkg, allocator);

    const key = try allocator.dupe(u8, "fixup.sh");
    const value = try allocator.dupe(u8, "sudo install -Dm755 helper /usr/bin/helper");
    try pkg.local_source_contents.put(key, value);

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expectEqualStrings("sudo", result.findings.items[0].tool);
    try std.testing.expectEqualStrings("source: fixup.sh", result.findings.items[0].hook);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "validateWithContent: sudo in build() function body is critical" {
    const allocator = std.testing.allocator;
    var pkg = try make_test_pkgbuild(allocator, null);
    defer deinit_test_pkgbuild(&pkg, allocator);

    const content =
        \\pkgname=pgadmin4-server
        \\build() {
        \\  sudo "$srcdir/parser"
        \\  cd "$srcdir/pgadmin4"
        \\}
        \\package() {
        \\  cp -r "${srcdir}/usr" "${pkgdir}/"
        \\}
    ;

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validateWithContent(pkg, content);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expectEqualStrings("sudo", result.findings.items[0].tool);
    try std.testing.expectEqualStrings("build", result.findings.items[0].hook);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "validateWithContent: risky tools in prepare and package are flagged per function" {
    const allocator = std.testing.allocator;
    var pkg = try make_test_pkgbuild(allocator, null);
    defer deinit_test_pkgbuild(&pkg, allocator);

    const content =
        \\pkgname=demo
        \\prepare() {
        \\  curl https://example.com/patch.sh | sh
        \\}
        \\package() {
        \\  doas install -Dm755 helper /usr/bin/helper
        \\}
    ;

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validateWithContent(pkg, content);
    defer result.deinit(std.testing.allocator);

    var saw_prepare_curl = false;
    var saw_package_doas = false;
    for (result.findings.items) |finding| {
        if (std.mem.eql(u8, finding.hook, "prepare") and std.mem.eql(u8, finding.tool, "curl")) saw_prepare_curl = true;
        if (std.mem.eql(u8, finding.hook, "package") and std.mem.eql(u8, finding.tool, "doas")) saw_package_doas = true;
    }
    try std.testing.expect(saw_prepare_curl);
    try std.testing.expect(saw_package_doas);
}

test "validateWithContent: benign function bodies produce no findings" {
    const allocator = std.testing.allocator;
    var pkg = try make_test_pkgbuild(allocator, null);
    defer deinit_test_pkgbuild(&pkg, allocator);

    const content =
        \\pkgname=demo
        \\build() {
        \\  make -j4
        \\}
        \\package() {
        \\  make DESTDIR="$pkgdir" install
        \\}
    ;

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validateWithContent(pkg, content);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
}

test "validate: risky tool in local_source_contents produces finding" {
    const allocator = std.testing.allocator;
    var pkg = try make_test_pkgbuild(allocator, null);
    defer deinit_test_pkgbuild(&pkg, allocator);

    const key = try allocator.dupe(u8, "install.sh");
    const value = try allocator.dupe(u8, "wget https://example.com/binary");
    try pkg.local_source_contents.put(key, value);

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqualStrings("wget", result.findings.items[0].tool);
    try std.testing.expectEqualStrings("source: install.sh", result.findings.items[0].hook);
}

test "validate: findings from both post_install and local_source_contents" {
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8, "curl https://example.com/a");
    var pkg = try make_test_pkgbuild(allocator, script);
    defer {
        deinit_test_pkgbuild(&pkg, allocator);
    }

    const key = try allocator.dupe(u8, "hook.sh");
    const value = try allocator.dupe(u8, "npm install -g some-package");
    try pkg.local_source_contents.put(key, value);

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    var saw_curl = false;
    var saw_npm = false;
    for (result.findings.items) |finding| {
        if (std.mem.eql(u8, finding.tool, "curl")) saw_curl = true;
        if (std.mem.eql(u8, finding.tool, "npm")) saw_npm = true;
    }
    try std.testing.expect(saw_curl);
    try std.testing.expect(saw_npm);
}

test "validate: multiple risky tools in post_install produce multiple findings" {
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8, "npm install && curl https://example.com/x");
    var pkg = try make_test_pkgbuild(allocator, script);
    defer {
        deinit_test_pkgbuild(&pkg, allocator);
    }

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqualStrings("npm", result.findings.items[0].tool);
    try std.testing.expectEqualStrings("curl", result.findings.items[1].tool);
}

test "validate: null post_install with risky local_source_contents" {
    const allocator = std.testing.allocator;
    var pkg = try make_test_pkgbuild(allocator, null);
    defer deinit_test_pkgbuild(&pkg, allocator);

    const key = try allocator.dupe(u8, "post.install");
    const value = try allocator.dupe(u8, "eval \"malicious code\"");
    try pkg.local_source_contents.put(key, value);

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.has_findings);
    // eval in local_source_contents should produce a critical finding
    try std.testing.expectEqual(shared_validator.ValidationSeverity.critical, result.findings.items[0].severity);
}

test "validate: empty post_install string produces no findings" {
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8, "");
    var pkg = try make_test_pkgbuild(allocator, script);
    defer {
        deinit_test_pkgbuild(&pkg, allocator);
    }

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.findings.items.len);
    try std.testing.expect(!result.has_findings);
}

test "validate: post_install with command substitution is warning" {
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8, "VAR=$(hostname)");
    var pkg = try make_test_pkgbuild(allocator, script);
    defer {
        deinit_test_pkgbuild(&pkg, allocator);
    }

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.findings.items.len);
    try std.testing.expect(result.has_findings);
    try std.testing.expectEqual(shared_validator.ValidationSeverity.warning, result.findings.items[0].severity);
}

test "validate: install script produces expected findings" {
    const install_script =
        \\# Colored makepkg-like functions
        \\_all_off="$(tput sgr0)"
        \\_bold="${_all_off}$(tput bold)"
        \\_green="${_bold}$(tput setaf 2)"
        \\note() {
        \\  printf "${_green}==>${_bold} %s${_all_off}\n" "$1"
        \\}
        \\
        \\post_install() {
        \\  note "The Acme Agent daemon is not started automatically."
        \\  note "To start it on boot, run 'sudo systemctl enable --now acme-agent' in a terminal."
        \\}
        \\
        \\post_upgrade() {
        \\  # Remind the user to enable the service if it is not enabled yet
        \\  systemctl -q is-enabled acme-agent.service || post_install
        \\
        \\  # Mark the service for restart (handled by the 30-systemd-restart-marked.hook pacman hook)
        \\  ! systemctl -q is-active acme-agent.service || systemctl set-property acme-agent.service Markers=needs-restart
        \\}
        \\
        \\pre_remove() {
        \\  if systemctl -q is-active acme-agent.service; then
        \\    note "The Acme Agent service may still be running after removal."
        \\    note "To stop it, run 'sudo systemctl stop acme-agent' in a terminal."
        \\  fi
        \\}
    ;
    const allocator = std.testing.allocator;
    const script = try allocator.dupe(u8, install_script);
    var pkg = try make_test_pkgbuild(allocator, script);
    defer deinit_test_pkgbuild(&pkg, allocator);

    const validator = PostInstallValidator{ .allocator = allocator };
    var result = try validator.validate(pkg);
    defer result.deinit(std.testing.allocator);

    // 3 warnings for the $(tput ...) color assignments and 2 critical sudo
    // findings (false positives: sudo only appears inside note() strings).
    try std.testing.expectEqual(@as(usize, 5), result.findings.items.len);
    try std.testing.expect(result.has_findings);

    var warning: usize = 0;
    var critical: usize = 0;
    for (result.findings.items) |finding| {
        switch (finding.severity) {
            .warning => warning += 1,
            .critical => critical += 1,
            .info => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 3), warning);
    try std.testing.expectEqual(@as(usize, 2), critical);

    for (result.findings.items) |finding| {
        if (finding.severity == shared_validator.ValidationSeverity.critical) {
            try std.testing.expectEqualStrings("sudo", finding.tool);
        } else {
            try std.testing.expectEqualStrings("<dynamic-command>", finding.tool);
        }
        try std.testing.expectEqualStrings("source: __test.install", finding.hook);
    }
}
