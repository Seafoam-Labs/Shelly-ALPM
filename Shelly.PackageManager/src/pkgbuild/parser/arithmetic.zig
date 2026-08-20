//! Bash $((...)) arithmetic evaluation with variable substitution.
const std = @import("std");
const PkgbuildParser = @import("parser.zig").PkgbuildParser;

fn tokenize(self: PkgbuildParser, expr: []const u8) ![][]const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer tokens.deinit(self.allocator);

    var i: usize = 0;
    while (i < expr.len) {
        if (std.ascii.isWhitespace(expr[i])) {
            i += 1;
            continue;
        }
        if (std.ascii.isDigit(expr[i])) {
            const start = i;
            while (i < expr.len and std.ascii.isDigit(expr[i])) i += 1;
            try tokens.append(self.allocator, expr[start..i]);
        } else if (std.mem.indexOfScalar(u8, "+-*/%()", expr[i]) != null) {
            try tokens.append(self.allocator, expr[i .. i + 1]);
            i += 1;
        } else {
            i += 1;
        }
    }
    return tokens.toOwnedSlice(self.allocator);
}

fn substitute_variables(self: PkgbuildParser, expr: []const u8, vars: *const std.StringHashMap([]const u8)) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.allocator);

    var i: usize = 0;
    while (i < expr.len) {
        if (expr[i] == '$') {
            var j = i + 1;
            const braced = j < expr.len and expr[j] == '{';
            if (braced) j += 1;
            const name_start = j;

            while (j < expr.len and (std.ascii.isAlphanumeric(expr[j]) or expr[j] == '_')) {
                j += 1;
            }

            if (j > name_start) {
                const name_end = j;
                var match_end = name_end;
                if (braced and match_end < expr.len and expr[match_end] == '}') {
                    match_end += 1;
                }

                const name = expr[name_start..name_end];
                var substituted = false;

                if (vars.get(name)) |val| {
                    if (std.fmt.parseInt(i64, val, 10)) |_| {
                        try out.appendSlice(self.allocator, val);
                        substituted = true;
                    } else |_| {}
                }

                if (!substituted) {
                    try out.appendSlice(self.allocator, expr[i..match_end]);
                }

                i = match_end;
                continue;
            }
        }

        if (std.ascii.isAlphabetic(expr[i]) or expr[i] == '_') {
            const name_start = i;
            var j = i + 1;
            while (j < expr.len and (std.ascii.isAlphanumeric(expr[j]) or expr[j] == '_')) : (j += 1) {}
            const name = expr[name_start..j];

            var substituted = false;
            if (vars.get(name)) |val| {
                if (std.fmt.parseInt(i64, val, 10)) |_| {
                    try out.appendSlice(self.allocator, val);
                    substituted = true;
                } else |_| {}
            }
            if (!substituted) {
                try out.appendSlice(self.allocator, name);
            }
            i = j;
            continue;
        }

        try out.append(self.allocator, expr[i]);
        i += 1;
    }

    return out.toOwnedSlice(self.allocator);
}

pub fn evaluate_arithmetic(self: PkgbuildParser, expr: []const u8, vars: *const std.StringHashMap([]const u8)) ![]u8 {
    const resolved = try substitute_variables(self, expr, vars);
    defer self.allocator.free(resolved);

    const value = compute: {
        const tokens = tokenize(self, resolved) catch break :compute null;
        defer self.allocator.free(tokens);
        var pos: usize = 0;
        break :compute eval_expression(tokens, 0, &pos) catch null;
    };

    if (value) |v| { //unwrap
        return std.fmt.allocPrint(self.allocator, "{d}", .{v});
    }

    std.debug.print("[Shelly] Warning: Cannot evaluate arithmetic: $(({s}))\n", .{expr});
    return self.allocator.dupe(u8, "0");
}

fn eval_expression(tokens: [][]const u8, pos: usize, new_pos: *usize) std.fmt.ParseIntError!i64 {
    var cur_pos: usize = undefined;
    var left = try eval_term(tokens, pos, &cur_pos);
    while (cur_pos < tokens.len and
        (std.mem.eql(u8, tokens[cur_pos], "+") or std.mem.eql(u8, tokens[cur_pos], "-")))
    {
        const op = tokens[cur_pos];
        cur_pos += 1;
        var next_pos: usize = undefined;
        const right = try eval_term(tokens, cur_pos, &next_pos);
        cur_pos = next_pos;
        left = if (std.mem.eql(u8, op, "+")) left + right else left - right;
    }
    new_pos.* = cur_pos;
    return left;
}

fn eval_term(tokens: [][]const u8, pos: usize, new_pos: *usize) std.fmt.ParseIntError!i64 {
    var cur_pos: usize = undefined;
    var left = try eval_factor(tokens, pos, &cur_pos);
    while (cur_pos < tokens.len and
        (std.mem.eql(u8, tokens[cur_pos], "*") or
            std.mem.eql(u8, tokens[cur_pos], "/") or
            std.mem.eql(u8, tokens[cur_pos], "%")))
    {
        const op = tokens[cur_pos];
        cur_pos += 1;
        var next_pos: usize = undefined;
        const right = try eval_factor(tokens, cur_pos, &next_pos);
        cur_pos = next_pos;
        left = if (std.mem.eql(u8, op, "*"))
            left * right
        else if (std.mem.eql(u8, op, "/"))
            @divTrunc(left, right)
        else
            @rem(left, right);
    }
    new_pos.* = cur_pos;
    return left;
}

fn eval_factor(tokens: [][]const u8, pos: usize, new_pos: *usize) std.fmt.ParseIntError!i64 {
    if (pos < tokens.len and std.mem.eql(u8, tokens[pos], "(")) {
        var cur_pos: usize = undefined;
        const val = try eval_expression(tokens, pos + 1, &cur_pos);
        if (cur_pos < tokens.len and std.mem.eql(u8, tokens[cur_pos], ")")) cur_pos += 1;
        new_pos.* = cur_pos;
        return val;
    }
    if (pos < tokens.len) {
        if (std.fmt.parseInt(i64, tokens[pos], 10)) |num| {
            new_pos.* = pos + 1;
            return num;
        } else |_| {}
    }
    new_pos.* = pos + 1;
    return 0;
}

test "eval_expression: single number" {
    const tokens = [_][]const u8{"42"};
    var new_pos: usize = undefined;
    const result = try eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 42), result);
    try std.testing.expectEqual(@as(usize, 1), new_pos);
}

test "eval_expression: simple addition" {
    const tokens = [_][]const u8{ "1", "+", "2" };
    var new_pos: usize = undefined;
    const result = try eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 3), result);
    try std.testing.expectEqual(@as(usize, 3), new_pos);
}

test "eval_expression: simple subtraction" {
    const tokens = [_][]const u8{ "5", "-", "3" };
    var new_pos: usize = undefined;
    const result = try eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 2), result);
}

test "eval_expression: operator precedence, multiplication before addition" {
    const tokens = [_][]const u8{ "2", "+", "3", "*", "4" };
    var new_pos: usize = undefined;
    const result = try eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 14), result);
}

test "eval_expression: division" {
    const tokens = [_][]const u8{ "10", "/", "2" };
    var new_pos: usize = undefined;
    const result = try eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 5), result);
}

test "eval_expression: modulo" {
    const tokens = [_][]const u8{ "10", "%", "3" };
    var new_pos: usize = undefined;
    const result = try eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "eval_expression: parentheses override precedence" {
    const tokens = [_][]const u8{ "(", "2", "+", "3", ")", "*", "4" };
    var new_pos: usize = undefined;
    const result = try eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 20), result);
}

test "eval_expression: nested parentheses" {
    const tokens = [_][]const u8{ "(", "(", "1", "+", "2", ")", "*", "(", "3", "+", "4", ")", ")" };
    var new_pos: usize = undefined;
    const result = try eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 21), result);
}

test "eval_expression: chained same-precedence operators" {
    const tokens = [_][]const u8{ "10", "-", "2", "-", "3" };
    var new_pos: usize = undefined;
    const result = try eval_expression(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 5), result);
}

test "eval_factor: unparseable token returns zero" {
    const tokens = [_][]const u8{"abc"};
    var new_pos: usize = undefined;
    const result = try eval_factor(@constCast(&tokens), 0, &new_pos);
    try std.testing.expectEqual(@as(i64, 0), result);
    try std.testing.expectEqual(@as(usize, 1), new_pos);
}

test "tokenize: single number" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try tokenize(parser, "42");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqualStrings("42", tokens[0]);
}

test "tokenize: simple expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try tokenize(parser, "1+2");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("1", tokens[0]);
    try std.testing.expectEqualStrings("+", tokens[1]);
    try std.testing.expectEqualStrings("2", tokens[2]);
}

test "tokenize: multi-digit numbers" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try tokenize(parser, "123*456");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("123", tokens[0]);
    try std.testing.expectEqualStrings("*", tokens[1]);
    try std.testing.expectEqualStrings("456", tokens[2]);
}

test "tokenize: ignores whitespace" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try tokenize(parser, "  1 + 2  ");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("1", tokens[0]);
    try std.testing.expectEqualStrings("+", tokens[1]);
    try std.testing.expectEqualStrings("2", tokens[2]);
}

test "tokenize: parentheses" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try tokenize(parser, "(1+2)*3");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 7), tokens.len);
    try std.testing.expectEqualStrings("(", tokens[0]);
    try std.testing.expectEqualStrings("1", tokens[1]);
    try std.testing.expectEqualStrings("+", tokens[2]);
    try std.testing.expectEqualStrings("2", tokens[3]);
    try std.testing.expectEqualStrings(")", tokens[4]);
    try std.testing.expectEqualStrings("*", tokens[5]);
    try std.testing.expectEqualStrings("3", tokens[6]);
}

test "tokenize: all operators" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try tokenize(parser, "+-*/%()");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 7), tokens.len);
    const expected = [_][]const u8{ "+", "-", "*", "/", "%", "(", ")" };
    for (tokens, expected) |got, want| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "tokenize: empty expression returns empty slice" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try tokenize(parser, "");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "tokenize: unknown characters are skipped" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    const tokens = try tokenize(parser, "1 & 2");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("1", tokens[0]);
    try std.testing.expectEqualStrings("2", tokens[1]);
}

test "substitute_variables: no variables in expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try substitute_variables(parser, "hello world", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "substitute_variables: single variable with integer value" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("EPOCH", "2");

    const result = try substitute_variables(parser, "pkgver=1.0.$EPOCH", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("pkgver=1.0.2", result);
}

test "substitute_variables: braced variable with integer value" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("REL", "3");

    const result = try substitute_variables(parser, "${REL}", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("3", result);
}

test "substitute_variables: variable not found keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try substitute_variables(parser, "value=$MISSING", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("value=$MISSING", result);
}

test "substitute_variables: non-integer value keeps original text" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("NAME", "hello");

    const result = try substitute_variables(parser, "$NAME", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("$NAME", result);
}

test "substitute_variables: mixed substituted and unsubstituted variables" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("A", "1");
    try vars.put("B", "not_a_number");

    const result = try substitute_variables(parser, "$A $B", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1 $B", result);
}

test "substitute_variables: multiple integer variables" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("X", "10");
    try vars.put("Y", "20");

    const result = try substitute_variables(parser, "$X+$Y", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("10+20", result);
}

test "substitute_variables: variable with underscore in name" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("MY_VAR", "42");

    const result = try substitute_variables(parser, "$MY_VAR", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "substitute_variables: dollar sign at end of string" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try substitute_variables(parser, "price$", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("price$", result);
}

test "substitute_variables: empty expression" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try substitute_variables(parser, "", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "substitute_variables: adjacent braced variables" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("A", "1");
    try vars.put("B", "2");

    const result = try substitute_variables(parser, "${A}${B}", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("12", result);
}

test "substitute_variables: negative integer value is substituted" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("NEG", "-5");

    const result = try substitute_variables(parser, "$NEG", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("-5", result);
}

test "substitute_variables: braced mixed with unbraced" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("X", "7");

    const result = try substitute_variables(parser, "$X and ${X}", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("7 and 7", result);
}

test "evaluate_arithmetic: simple addition" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try evaluate_arithmetic(parser, "1 + 2", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("3", result);
}

test "evaluate_arithmetic: simple subtraction" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try evaluate_arithmetic(parser, "10 - 3", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("7", result);
}

test "evaluate_arithmetic: multiplication" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try evaluate_arithmetic(parser, "4 * 5", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("20", result);
}

test "evaluate_arithmetic: division" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try evaluate_arithmetic(parser, "15 / 3", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("5", result);
}

test "evaluate_arithmetic: modulo" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try evaluate_arithmetic(parser, "10 % 3", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1", result);
}

test "evaluate_arithmetic: operator precedence" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try evaluate_arithmetic(parser, "2 + 3 * 4", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("14", result);
}

test "evaluate_arithmetic: parentheses override precedence" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try evaluate_arithmetic(parser, "(2 + 3) * 4", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("20", result);
}

test "evaluate_arithmetic: single number" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try evaluate_arithmetic(parser, "42", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "evaluate_arithmetic: variable substitution with arithmetic" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("EPOCH", "1");
    try vars.put("REL", "2");

    const result = try evaluate_arithmetic(parser, "$EPOCH + $REL", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("3", result);
}

test "evaluate_arithmetic: braced variable substitution" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("X", "10");
    try vars.put("Y", "5");

    const result = try evaluate_arithmetic(parser, "${X} - ${Y}", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("5", result);
}

test "evaluate_arithmetic: variable with non-integer value falls back to 0" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    try vars.put("BAD", "hello");

    const result = try evaluate_arithmetic(parser, "$BAD + 1", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("0", result);
}

test "evaluate_arithmetic: unresolvable expression returns 0" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try evaluate_arithmetic(parser, "foo + bar", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("0", result);
}

test "evaluate_arithmetic: nested parentheses" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try evaluate_arithmetic(parser, "((2 + 3) * (4 - 1))", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("15", result);
}

test "evaluate_arithmetic: chained operators" {
    const parser = PkgbuildParser{ .allocator = std.testing.allocator, .io = std.testing.io };
    var vars: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer vars.deinit();

    const result = try evaluate_arithmetic(parser, "1 + 2 + 3 + 4", &vars);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("10", result);
}
