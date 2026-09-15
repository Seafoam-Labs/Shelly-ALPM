//! Shell words retain quote provenance until expansion. No shell is executed.
const std = @import("std");
const scan = @import("shell_scan.zig");

pub const Kind = enum { literal, unquoted, parameter };
pub const Part = struct { start: usize, end: usize, kind: Kind };
pub const Word = struct {
    end: usize,
    parts: []Part,
    pub fn deinit(self: Word, allocator: std.mem.Allocator) void {
        allocator.free(self.parts);
    }
    pub fn decoded(self: Word, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.parts) |part| try out.appendSlice(allocator, input[part.start..part.end]);
        return out.toOwnedSlice(allocator);
    }
};

/// Balanced parameter/command expressions are opaque to the outer word.
/// Unsupported expressions are retained for the reviewed evaluator.
pub fn expressionEnd(input: []const u8, start: usize) !usize {
    if (input[start] == '`') {
        var i = start + 1;
        while (i < input.len) : (i += 1) {
            if (input[i] == '\\') {
                i += 1;
                continue;
            }
            if (input[i] == '`') return i + 1;
        }
        return error.UnsupportedShellWord;
    }
    if (start + 1 >= input.len) return start + 1;
    const open = input[start + 1];
    if (open != '{' and open != '(') return scan.scan_word_chars(input, start + 1);
    const close: u8 = if (open == '{') '}' else ')';
    var depth: usize = 1;
    var quote: u8 = 0;
    var i = start + 2;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '\\' and quote != '\'') {
            i += 1;
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return error.UnsupportedShellWord;
}

pub fn read(allocator: std.mem.Allocator, input: []const u8, start: usize) !Word {
    var parts: std.ArrayList(Part) = .empty;
    errdefer parts.deinit(allocator);
    var quote: u8 = 0;
    var i = start;
    while (i < input.len) {
        const c = input[i];
        if (quote == 0 and (std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, ";&|()<>", c) != null)) break;
        if ((c == '\'' or c == '"') and (quote == 0 or quote == c)) {
            quote = if (quote == 0) c else 0;
            i += 1;
            continue;
        }
        if (c == '\\' and quote != '\'') {
            if (i + 1 == input.len) return error.UnsupportedShellWord;
            const next = input[i + 1];
            if (next == '\n') {
                i += 2;
                continue;
            }
            if (quote == 0 or std.mem.indexOfScalar(u8, "$`\"\\", next) != null) {
                try parts.append(allocator, .{ .start = i + 1, .end = i + 2, .kind = .literal });
                i += 2;
                continue;
            }
        }
        if (quote != '\'' and (c == '`' or (c == '$' and i + 1 < input.len and
            (scan.is_word(input[i + 1]) or input[i + 1] == '{' or input[i + 1] == '('))))
        {
            const end = try expressionEnd(input, i);
            try parts.append(allocator, .{ .start = i, .end = end, .kind = .parameter });
            i = end;
            continue;
        }
        const kind: Kind = if (quote == 0) .unquoted else .literal;
        if (parts.items.len > 0 and parts.items[parts.items.len - 1].kind == kind and parts.items[parts.items.len - 1].end == i) {
            parts.items[parts.items.len - 1].end = i + 1;
        } else try parts.append(allocator, .{ .start = i, .end = i + 1, .kind = kind });
        i += 1;
    }
    if (quote != 0) return error.UnsupportedShellWord;
    return .{ .end = i, .parts = try parts.toOwnedSlice(allocator) };
}

pub const Assignment = struct {
    name: []const u8,
    raw: []const u8,
    append: bool,
    offset: usize,
    deferred: bool,
};

/// Walk simple assignments in command order, excluding function/subshell bodies.
/// Conditional assignments are returned as deferred, never executed statically.
pub const Assignments = struct {
    input: []const u8,
    pos: usize = 0,
    command_start: bool = true,
    group_depth: usize = 0,
    conditional_depth: usize = 0,
    conditional_command: bool = false,

    pub fn next(self: *Assignments, allocator: std.mem.Allocator) !?Assignment {
        while (self.pos < self.input.len) {
            const start = self.pos;
            const c = self.input[start];
            if (std.ascii.isWhitespace(c)) {
                if (c == '\n') {
                    self.command_start = true;
                    self.conditional_command = false;
                }
                self.pos += 1;
                continue;
            }
            if (c == '#') {
                self.pos = std.mem.indexOfScalarPos(u8, self.input, start, '\n') orelse self.input.len;
                continue;
            }
            if (c == '\\' and start + 1 < self.input.len and self.input[start + 1] == '\n') {
                self.pos += 2;
                continue;
            }
            if (std.mem.indexOfScalar(u8, ";&|", c) != null) {
                self.conditional_command = c != ';';
                self.pos += 1;
                self.command_start = true;
                continue;
            }
            if (c == '(' or c == '{') {
                self.group_depth += 1;
                self.pos += 1;
                self.command_start = true;
                continue;
            }
            if (c == ')' or c == '}') {
                self.group_depth -|= 1;
                self.pos += 1;
                self.command_start = true;
                continue;
            }
            if (c == '<' or c == '>') {
                // A top-level heredoc cannot be treated as assignments. Leave
                // its command and body to Bash rather than scanning body text.
                if (std.mem.startsWith(u8, self.input[start..], "<<") and !std.mem.startsWith(u8, self.input[start..], "<<<")) {
                    self.pos = try skipHeredocCommand(allocator, self.input, start);
                    self.command_start = true;
                    self.conditional_command = false;
                    continue;
                }
                self.pos += 1;
                self.command_start = false;
                continue;
            }
            var cursor = scan.scan_word_chars(self.input, start);
            if (cursor > start and (std.ascii.isAlphabetic(c) or c == '_') and self.command_start) {
                const name = self.input[start..cursor];
                const append = cursor < self.input.len and self.input[cursor] == '+';
                if (append) cursor += 1;
                if (cursor < self.input.len and self.input[cursor] == '=') {
                    const value_start = cursor + 1;
                    if (value_start < self.input.len and self.input[value_start] == '(') {
                        // Array bodies may span lines; don't mistake their
                        // contents for scalar assignments.
                        var depth: usize = 1;
                        self.pos = value_start + 1;
                        while (self.pos < self.input.len and depth > 0) {
                            const a = self.input[self.pos];
                            if (a == '(') {
                                depth += 1;
                                self.pos += 1;
                            } else if (a == ')') {
                                depth -= 1;
                                self.pos += 1;
                            } else if (std.ascii.isWhitespace(a)) {
                                self.pos += 1;
                            } else if (a == '#') {
                                self.pos = std.mem.indexOfScalarPos(u8, self.input, self.pos, '\n') orelse self.input.len;
                            } else {
                                const item = try read(allocator, self.input, self.pos);
                                defer item.deinit(allocator);
                                self.pos = if (item.end > self.pos) item.end else self.pos + 1;
                            }
                        }
                        if (depth != 0) return error.UnsupportedShellWord;
                    } else {
                        const value = try read(allocator, self.input, value_start);
                        defer value.deinit(allocator);
                        self.pos = value.end;
                    }
                    if (self.group_depth != 0) continue;
                    // Assignment prefixes of an external command have temporary
                    // environment scope; don't install their values globally.
                    var tail = self.pos;
                    while (tail < self.input.len and (self.input[tail] == ' ' or self.input[tail] == '\t')) tail += 1;
                    var temporary_scope = false;
                    if (tail < self.input.len and std.mem.indexOfScalar(u8, "\n\r;#&|", self.input[tail]) == null) {
                        var name_end = scan.scan_word_chars(self.input, tail);
                        if (name_end < self.input.len and self.input[name_end] == '+') name_end += 1;
                        temporary_scope = name_end == tail or name_end == self.input.len or self.input[name_end] != '=';
                    }
                    return .{ .name = name, .raw = self.input[value_start..self.pos], .append = append, .offset = start, .deferred = self.conditional_depth != 0 or self.conditional_command or temporary_scope };
                }
            }
            const token = try read(allocator, self.input, start);
            defer token.deinit(allocator);
            if (token.end == start) {
                self.pos += 1;
                continue;
            }
            const raw = self.input[start..token.end];
            if (self.command_start and self.group_depth == 0) {
                var function_name = raw;
                if (std.mem.eql(u8, raw, "function")) {
                    const name_start = scan.skip_ws(self.input, token.end);
                    const name_word = try read(allocator, self.input, name_start);
                    defer name_word.deinit(allocator);
                    function_name = self.input[name_start..name_word.end];
                }
                const after = scan.skip_ws(self.input, token.end);
                if (std.mem.eql(u8, raw, "function") or std.mem.startsWith(u8, self.input[after..], "()")) {
                    if (try @import("function_body.zig").function_end(self.input[start..], function_name)) |end| {
                        self.pos = start + end;
                        self.command_start = false;
                        continue;
                    }
                }
            }
            self.pos = token.end;
            if (self.group_depth == 0 and self.command_start) {
                inline for (.{ "if", "for", "while", "until", "case", "select" }) |keyword| {
                    if (std.mem.eql(u8, raw, keyword)) {
                        self.conditional_depth += 1;
                        break;
                    }
                }
                inline for (.{ "fi", "done", "esac" }) |keyword| {
                    if (std.mem.eql(u8, raw, keyword)) {
                        self.conditional_depth -|= 1;
                        break;
                    }
                }
            }
            self.command_start = std.mem.eql(u8, raw, "then") or std.mem.eql(u8, raw, "else") or std.mem.eql(u8, raw, "do");
        }
        return null;
    }
};

fn skipHeredocCommand(allocator: std.mem.Allocator, input: []const u8, start: usize) !usize {
    var declarations: std.ArrayList(scan.heredoc_declaration) = .empty;
    defer {
        for (declarations.items) |declaration| allocator.free(declaration.delimiter);
        declarations.deinit(allocator);
    }
    var i = start;
    while (i < input.len and input[i] != '\n') {
        if (std.mem.startsWith(u8, input[i..], "<<") and !std.mem.startsWith(u8, input[i..], "<<<")) {
            const declaration = try scan.parse_heredoc(allocator, input, i + 2) orelse return error.UnsupportedShellWord;
            declarations.append(allocator, declaration) catch |err| {
                allocator.free(declaration.delimiter);
                return err;
            };
            i = declaration.end;
        } else if (std.ascii.isWhitespace(input[i]) or std.mem.indexOfScalar(u8, "|&;<>", input[i]) != null) {
            i += 1;
        } else {
            const token = try read(allocator, input, i);
            defer token.deinit(allocator);
            i = if (token.end > i) token.end else i + 1;
        }
    }
    if (i < input.len) i += 1;
    for (declarations.items) |declaration| {
        var found = false;
        while (i < input.len) {
            const end = std.mem.indexOfScalarPos(u8, input, i, '\n') orelse input.len;
            var line = std.mem.trimEnd(u8, input[i..end], "\r");
            if (declaration.strip_tabs) line = std.mem.trimStart(u8, line, "\t");
            i = if (end < input.len) end + 1 else end;
            if (std.mem.eql(u8, line, declaration.delimiter)) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnsupportedShellWord;
    }
    return i;
}
