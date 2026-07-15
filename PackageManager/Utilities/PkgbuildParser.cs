using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace PackageManager.Utilities;

/// <summary>
/// Parser for Arch Linux PKGBUILD files.
/// </summary>
public static class PkgbuildParser
{

    public static PkgbuildInfo Parse(string pkgbuildPath)
    {
        var pkgbuildContent = File.ReadAllText(pkgbuildPath);
        return ParseContent(pkgbuildContent, Path.GetDirectoryName(pkgbuildPath));
    }

    public static PkgbuildInfo ParseContent(string pkgbuildContent, string? baseDir = null)
    {
        var vars = BuildVariableDictionary(pkgbuildContent);
        ScanPrepareForLiteralAssignments(pkgbuildContent, vars);

        var rawInstall = ResolveOrParse(pkgbuildContent, vars, "install");
        var installFile = rawInstall is null ? null : ResolveString(rawInstall, vars);

        var source = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "source", vars));
        var localSourceFiles = ExtractLocalSourceFiles(source);
        var localSourceContents = ResolveLocalSourceContents(localSourceFiles, baseDir);

        return new PkgbuildInfo
        {
            Variables = new Dictionary<string, string>(vars),
            PkgName = ResolveOrParse(pkgbuildContent, vars, "pkgname"),
            PkgVer = ResolveOrParse(pkgbuildContent, vars, "pkgver"),
            PkgRel = ResolveOrParse(pkgbuildContent, vars, "pkgrel"),
            Epoch = ResolveOrParse(pkgbuildContent, vars, "epoch"),
            PkgDesc = ResolveOrParse(pkgbuildContent, vars, "pkgdesc"),
            Url = ResolveOrParse(pkgbuildContent, vars, "url"),
            License = ParseArray(pkgbuildContent, "license", vars),
            Arch = ParseArray(pkgbuildContent, "arch", vars),
            Depends = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "depends", vars)),
            MakeDepends = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "makedepends", vars)),
            CheckDepends = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "checkdepends", vars)),
            OptDepends = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "optdepends", vars)),
            Provides = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "provides", vars)),
            Conflicts = ParseArray(pkgbuildContent, "conflicts", vars),
            Replaces = ParseArray(pkgbuildContent, "replaces", vars),
            Source = source,
            Sha256Sums = ParseArray(pkgbuildContent, "sha256sums", vars),
            Sha512Sums = ParseArray(pkgbuildContent, "sha512sums", vars),
            Md5Sums = ParseArray(pkgbuildContent, "md5sums", vars),

            InstallFile = installFile,
            PostInstall = ResolvePostInstall(installFile, baseDir)
                          ?? ExtractFunctionBody(pkgbuildContent, "post_install"),

            LocalSourceFiles = localSourceFiles,
            LocalSourceContents = localSourceContents
        };
    }

    private static readonly string[] LocalSourceExtensions =
    [
        ".sh", ".bash", ".install", ".patch", ".diff", ".desktop",
        ".py", ".pl", ".rb", ".service", ".conf", ".cfg", ".hook"
    ];

    private static List<string> ExtractLocalSourceFiles(List<string> source)
    {
        var files = new List<string>();
        foreach (var entry in source)
        {
            var (fileName, location) = SplitSourceEntry(entry);
            if (IsRemoteSource(location))
                continue;

            var name = string.IsNullOrWhiteSpace(fileName) ? location : fileName;
            if (string.IsNullOrWhiteSpace(name))
                continue;

            var ext = Path.GetExtension(name).ToLowerInvariant();
            if (!LocalSourceExtensions.Contains(ext))
                continue;

            if (!files.Contains(name))
                files.Add(name);
        }

        return files;
    }

    private static (string fileName, string location) SplitSourceEntry(string entry)
    {
        var idx = entry.IndexOf("::", StringComparison.Ordinal);
        if (idx < 0)
            return (string.Empty, entry.Trim());

        var name = entry.Substring(0, idx).Trim();
        var loc = entry.Substring(idx + 2).Trim();
        return (name, loc);
    }

    private static bool IsRemoteSource(string location)
    {
        return Regex.IsMatch(location,
            @"^(https?|ftp|ftps|git\+|svn\+|hg\+|bzr\+|git|svn|hg|bzr|rsync|file)(://|\+)",
            RegexOptions.IgnoreCase)
            || location.Contains("://");
    }

    private static Dictionary<string, string> ResolveLocalSourceContents(List<string> localSourceFiles, string? baseDir)
    {
        var contents = new Dictionary<string, string>();
        foreach (var fileName in localSourceFiles)
        {
            var resolved = ResolveLocalFile(fileName, baseDir);
            if (resolved is not null)
                contents[fileName] = resolved;
        }

        return contents;
    }

    private static string? ResolveLocalFile(string fileName, string? baseDir)
    {
        if (string.IsNullOrWhiteSpace(fileName))
            return null;

        var path = baseDir is null ? fileName : Path.Combine(baseDir, fileName);
        if (!File.Exists(path))
        {
            System.Console.Error.WriteLine(
                $"[Shelly] Warning: source file not found: {path}");
            return null;
        }

        return File.ReadAllText(path);
    }

    private static string? ResolvePostInstall(string? installFile, string? baseDir)
    {
        if (string.IsNullOrWhiteSpace(installFile))
            return null;

        var path = baseDir is null ? installFile : Path.Combine(baseDir, installFile);
        if (!File.Exists(path))
        {
            System.Console.Error.WriteLine(
                $"[Shelly] Warning: install file not found: {path}");
            return null;
        }

        var installContent = File.ReadAllText(path);
        return ExtractFunctionBody(installContent, "post_install");
    }

    private static string? ExtractFunctionBody(string content, string functionName)
    {
        var headerMatch = Regex.Match(
            content,
            $@"^\s*(?:function\s+)?{Regex.Escape(functionName)}\s*\(\s*\)\s*\{{",
            RegexOptions.Multiline);
        if (!headerMatch.Success)
            return null;

        var start = headerMatch.Index + headerMatch.Length;
        var depth = 1;
        var i = start;
        while (i < content.Length && depth > 0)
        {
            var c = content[i];
            if (c == '{') depth++;
            else if (c == '}') depth--;
            i++;
        }

        return content.Substring(start, System.Math.Max(0, i - start - 1)).Trim();
    }


    private static void ScanPrepareForLiteralAssignments(string content, Dictionary<string, string> vars)
    {
        var prepareMatch = Regex.Match(content, @"prepare\s*\(\s*\)\s*\{", RegexOptions.Multiline);
        if (!prepareMatch.Success)
            return;

        var start = prepareMatch.Index + prepareMatch.Length;
        var depth = 1;
        var i = start;
        while (i < content.Length && depth > 0)
        {
            var c = content[i];
            if (c == '{') depth++;
            else if (c == '}') depth--;
            i++;
        }
        var body = content.Substring(start, System.Math.Max(0, i - start - 1));

        var pattern = @"^\s*(\w+)=(?:""([^""$`]*)""|'([^']*)'|([A-Za-z0-9_./:\-+]+))\s*$";
        foreach (Match m in Regex.Matches(body, pattern, RegexOptions.Multiline))
        {
            var name = m.Groups[1].Value;
            var value = m.Groups[2].Success ? m.Groups[2].Value :
                        m.Groups[3].Success ? m.Groups[3].Value :
                        m.Groups[4].Value;
            if (string.IsNullOrEmpty(value)) continue;
            if (value.Contains('$') || value.Contains('`')) continue;
            vars.TryAdd(name, value);
        }

        for (var pass = 0; pass < 10; pass++)
        {
            var changed = false;
            foreach (var key in vars.Keys.ToList())
            {
                var original = vars[key];
                var resolved = ResolveString(original, vars);
                if (resolved != original)
                {
                    vars[key] = resolved;
                    changed = true;
                }
            }
            if (!changed) break;
        }
    }

    private static Dictionary<string, string> BuildVariableDictionary(string content)
    {
        var vars = new Dictionary<string, string>();

        // Match: varname="value", varname='value', varname=value (not arrays)
        var pattern = @"^(\w+)=(?:""([^""]*)""|'([^']*)'|(\S+))";
        foreach (Match match in Regex.Matches(content, pattern, RegexOptions.Multiline))
        {
            var name = match.Groups[1].Value;
            var value = match.Groups[2].Success ? match.Groups[2].Value :
                        match.Groups[3].Success ? match.Groups[3].Value :
                        match.Groups[4].Value;

            // Skip if value is an array opening paren or command substitution (but not arithmetic $((...)
            if (value.StartsWith("(") || (value.StartsWith("$(") && !value.StartsWith("$(("))) continue;

            vars[name] = value;
        }

        // Multi-pass resolution for chained variables: _a=1; _b=$_a; _c=$_b
        for (var pass = 0; pass < 10; pass++)
        {
            var changed = false;
            foreach (var key in vars.Keys.ToList())
            {
                var original = vars[key];
                var resolved = ResolveString(original, vars);
                if (resolved != original)
                {
                    vars[key] = resolved;
                    changed = true;
                }
            }
            if (!changed) break;
        }

        return vars;
    }


    private static string ResolveString(string input, Dictionary<string, string> vars)
    {

        var result = Regex.Replace(input, @"\$\(\(([^)]+)\)\)", match =>
        {
            return EvaluateArithmetic(match.Groups[1].Value, vars);
        });


        result = Regex.Replace(result, @"\$\([^)]+\)", match =>
        {
            System.Console.Error.WriteLine(
                $"[Shelly] Warning: Cannot evaluate command substitution: {match.Value}");
            return "";
        });


        result = Regex.Replace(result, @"\$\{(\w+)(##|#|%%|%)([^}]*)\}", match =>
        {
            var varName = match.Groups[1].Value;
            if (!vars.TryGetValue(varName, out var val))
                return match.Value;
            return ApplyParameterExpansion(val, match.Groups[2].Value, match.Groups[3].Value);
        });


        result = Regex.Replace(result, @"\$\{(\w+)/(/|#|%)?([^/}]*)(?:/([^}]*))?\}", match =>
        {
            var varName = match.Groups[1].Value;
            if (!vars.TryGetValue(varName, out var val))
                return match.Value;
            return ApplyReplacement(val, match.Groups[2].Value, match.Groups[3].Value, match.Groups[4].Value);
        });


        result = Regex.Replace(result, @"\$\{(\w+):(?:\s*(\d+)|\s+(-\d+))(?::\s*(-?\d+))?\}", match =>
        {
            var varName = match.Groups[1].Value;
            if (!vars.TryGetValue(varName, out var val))
                return match.Value;
            var offset = int.Parse(match.Groups[2].Success ? match.Groups[2].Value : match.Groups[3].Value);
            int? length = match.Groups[4].Success ? int.Parse(match.Groups[4].Value) : null;
            return ApplySubstring(val, offset, length);
        });


        result = Regex.Replace(result, @"\$\{(\w+)\}|\$(\w+)", match =>
        {
            var varName = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
            return vars.TryGetValue(varName, out var val) ? val : match.Value;
        });

        return result;
    }

    private static string ApplyParameterExpansion(string value, string op, string glob)
    {
        if (string.IsNullOrEmpty(glob))
            return value;

        var pattern = GlobToRegex(glob);

        switch (op)
        {
            case "#":
                for (var j = 0; j <= value.Length; j++)
                    if (Regex.IsMatch(value[..j], "^" + pattern + "$"))
                        return value[j..];
                return value;

            case "##":
                for (var j = value.Length; j >= 0; j--)
                    if (Regex.IsMatch(value[..j], "^" + pattern + "$"))
                        return value[j..];
                return value;

            case "%":
                for (var i = value.Length; i >= 0; i--)
                    if (Regex.IsMatch(value[i..], "^" + pattern + "$"))
                        return value[..i];
                return value;

            case "%%":
                for (var i = 0; i <= value.Length; i++)
                    if (Regex.IsMatch(value[i..], "^" + pattern + "$"))
                        return value[..i];
                return value;

            default:
                return value;
        }
    }

    private static string ApplyReplacement(string value, string mode, string findGlob, string repl)
    {
        if (string.IsNullOrEmpty(findGlob))
            return value;

        var pattern = GlobToRegex(findGlob);
        if (mode == "#") pattern = "^" + pattern;
        else if (mode == "%") pattern = pattern + "$";

        try
        {
            var regex = new Regex(pattern);
            var count = mode == "/" ? int.MaxValue : 1;
            return regex.Replace(value, _ => repl, count);
        }
        catch
        {
            return value;
        }
    }

    private static string ApplySubstring(string value, int offset, int? length)
    {
        var start = offset < 0 ? value.Length + offset : offset;
        start = System.Math.Clamp(start, 0, value.Length);

        int end;
        if (length is null)
            end = value.Length;
        else if (length < 0)
            end = value.Length + length.Value;
        else
            end = start + length.Value;

        end = System.Math.Clamp(end, start, value.Length);
        return value[start..end];
    }

    private static string GlobToRegex(string glob)
    {
        var sb = new StringBuilder();
        foreach (var c in glob)
        {
            switch (c)
            {
                case '*': sb.Append(".*"); break;
                case '?': sb.Append('.'); break;
                default:
                    if (@"\^$.|+()[]{}".Contains(c))
                        sb.Append('\\');
                    sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }


    private static string EvaluateArithmetic(string expr, Dictionary<string, string> vars)
    {

        var resolved = Regex.Replace(expr, @"\$\{?(\w+)\}?", match =>
        {
            var name = match.Groups[1].Value;
            if (vars.TryGetValue(name, out var val) && long.TryParse(val, out _))
                return val;
            return match.Value;
        });

        try
        {
            var tokens = Tokenize(resolved);
            var value = EvalExpression(tokens, 0, out _);
            return value.ToString();
        }
        catch
        {
            System.Console.Error.WriteLine($"[Shelly] Warning: Cannot evaluate arithmetic: $(({expr}))");
            return "0";
        }
    }

    private static List<string> Tokenize(string expr)
    {
        var tokens = new List<string>();
        var i = 0;
        while (i < expr.Length)
        {
            if (char.IsWhiteSpace(expr[i])) { i++; continue; }
            if (char.IsDigit(expr[i]))
            {
                var start = i;
                while (i < expr.Length && char.IsDigit(expr[i])) i++;
                tokens.Add(expr[start..i]);
            }
            else if ("+-*/%()".Contains(expr[i]))
            {
                tokens.Add(expr[i].ToString());
                i++;
            }
            else i++;
        }
        return tokens;
    }

    private static long EvalExpression(List<string> tokens, int pos, out int newPos)
    {
        var left = EvalTerm(tokens, pos, out pos);
        while (pos < tokens.Count && (tokens[pos] == "+" || tokens[pos] == "-"))
        {
            var op = tokens[pos++];
            var right = EvalTerm(tokens, pos, out pos);
            left = op == "+" ? left + right : left - right;
        }
        newPos = pos;
        return left;
    }

    private static long EvalTerm(List<string> tokens, int pos, out int newPos)
    {
        var left = EvalFactor(tokens, pos, out pos);
        while (pos < tokens.Count && (tokens[pos] == "*" || tokens[pos] == "/" || tokens[pos] == "%"))
        {
            var op = tokens[pos++];
            var right = EvalFactor(tokens, pos, out pos);
            left = op == "*" ? left * right : op == "/" ? left / right : left % right;
        }
        newPos = pos;
        return left;
    }

    private static long EvalFactor(List<string> tokens, int pos, out int newPos)
    {
        if (pos < tokens.Count && tokens[pos] == "(")
        {
            var val = EvalExpression(tokens, pos + 1, out pos);
            if (pos < tokens.Count && tokens[pos] == ")") pos++;
            newPos = pos;
            return val;
        }
        if (pos < tokens.Count && long.TryParse(tokens[pos], out var num))
        {
            newPos = pos + 1;
            return num;
        }
        newPos = pos + 1;
        return 0;
    }


    private static string? ParseVariable(string content, string variableName)
    {
        var pattern = $@"^{variableName}=(?:""([^""]*)""|'([^']*)'|(\S+))";
        var match = Regex.Match(content, pattern, RegexOptions.Multiline);

        if (match.Success)
        {
            return match.Groups[1].Success ? match.Groups[1].Value :
                match.Groups[2].Success ? match.Groups[2].Value :
                match.Groups[3].Value;
        }

        return null;
    }

    private static string? ResolveOrParse(string content, Dictionary<string, string> vars, string varName)
    {
        return vars.TryGetValue(varName, out var val) ? val : ParseVariable(content, varName);
    }



    private static List<string> ParseArray(
        string content,
        string variableName,
        Dictionary<string, string> vars)
    {
        var result = new List<string>();

        // Besides ordinary array assignments, accept a common PKGBUILD idiom:
        //   [[ $_feature -eq 1 ]] && makedepends+=('conditional-dependency')
        // Only guards that can be resolved from literal scalar variables are evaluated.
        // More complex shell conditions remain skipped rather than being guessed.
        var startPattern =
            $@"^(?:(?<guard>\[\[[^\r\n]*\]\])\s*&&\s*)?{Regex.Escape(variableName)}\+?=\(";
        var starts = Regex.Matches(content, startPattern, RegexOptions.Multiline);

        foreach (Match match in starts)
        {
            var guard = match.Groups["guard"];
            if (guard.Success)
            {
                if (!TryEvaluateConditionalGuard(guard.Value, vars, out var includeAssignment))
                {
                    System.Console.Error.WriteLine(
                        $"[Shelly] Skipping unsupported conditional {variableName}+=() at offset {match.Index}");
                    continue;
                }

                if (!includeAssignment)
                    continue;
            }
            else if (IsInsideConditionalBlock(content, match.Index))
            {
                System.Console.Error.WriteLine(
                    $"[Shelly] Skipping conditional {variableName}+=() at offset {match.Index}");
                continue;
            }

            var i = match.Index + match.Length;
            bool inS = false, inD = false;
            var sb = new StringBuilder();
            for (; i < content.Length; i++)
            {
                var c = content[i];
                if (c == '\\' && i + 1 < content.Length)
                {
                    sb.Append(c).Append(content[++i]);
                    continue;
                }
                if (c == '\'' && !inD) { inS = !inS; sb.Append(c); continue; }
                if (c == '"' && !inS) { inD = !inD; sb.Append(c); continue; }
                if (c == ')' && !inS && !inD) break;
                sb.Append(c);
            }

            var arrayContent = sb.ToString();
            var lines = arrayContent.Split('\n');
            var cleanedContent = string.Join("\n", lines.Select(StripComment));

            var itemPattern = @"""([^""]*)""" + @"|'([^']*)'|(\S+)";
            var itemMatches = Regex.Matches(cleanedContent, itemPattern);

            foreach (Match itemMatch in itemMatches)
            {
                var value = itemMatch.Groups[1].Success ? itemMatch.Groups[1].Value :
                    itemMatch.Groups[2].Success ? itemMatch.Groups[2].Value :
                    itemMatch.Groups[3].Value;

                result.Add(value);
            }
        }

        return result;
    }

    private static bool TryEvaluateConditionalGuard(
        string guard,
        Dictionary<string, string> vars,
        out bool result)
    {
        result = false;
        if (guard.Length < 4)
            return false;

        var expression = guard[2..^2].Trim();
        var match = Regex.Match(
            expression,
            @"^(?<left>(?:""[^""]*""|'[^']*'|\S+))\s+" +
            @"(?<operator>-eq|-ne|-gt|-ge|-lt|-le|==|!=)\s+" +
            @"(?<right>(?:""[^""]*""|'[^']*'|\S+))$");
        if (!match.Success)
            return false;

        var left = ResolveConditionalOperand(match.Groups["left"].Value, vars);
        var right = ResolveConditionalOperand(match.Groups["right"].Value, vars);
        if (left.Contains('$') || right.Contains('$'))
            return false;

        switch (match.Groups["operator"].Value)
        {
            case "==":
                result = string.Equals(left, right, StringComparison.Ordinal);
                return true;
            case "!=":
                result = !string.Equals(left, right, StringComparison.Ordinal);
                return true;
        }

        if (!long.TryParse(left, out var leftNumber) || !long.TryParse(right, out var rightNumber))
            return false;

        result = match.Groups["operator"].Value switch
        {
            "-eq" => leftNumber == rightNumber,
            "-ne" => leftNumber != rightNumber,
            "-gt" => leftNumber > rightNumber,
            "-ge" => leftNumber >= rightNumber,
            "-lt" => leftNumber < rightNumber,
            "-le" => leftNumber <= rightNumber,
            _ => false
        };
        return true;
    }

    private static string ResolveConditionalOperand(string operand, Dictionary<string, string> vars)
    {
        if (operand.Length >= 2 &&
            ((operand[0] == '\'' && operand[^1] == '\'') ||
             (operand[0] == '"' && operand[^1] == '"')))
        {
            operand = operand[1..^1];
        }

        return ResolveString(operand, vars);
    }


    private static bool IsInsideConditionalBlock(string content, int position)
    {
        var before = content.Substring(0, position);
        var depth = 0;
        foreach (Match m in Regex.Matches(before, @"(?:^|;|\s)(if|fi)\b", RegexOptions.Multiline))
        {
            var keyword = m.Groups[1].Value;
            if (keyword == "if") depth++;
            else if (keyword == "fi") depth = System.Math.Max(0, depth - 1);
        }
        return depth > 0;
    }

    private static string StripComment(string line)
    {
        var inSingleQ = false;
        var inDoubleQ = false;
        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];
            if (c == '"' && !inSingleQ) inDoubleQ = !inDoubleQ;
            else if (c == '\'' && !inDoubleQ) inSingleQ = !inSingleQ;
            else if (c == '#' && !inSingleQ && !inDoubleQ)
                return line.Substring(0, i);
        }
        return line;
    }

    private static List<string> ResolveVariableReferences(string content, Dictionary<string, string> vars, List<string> items)
    {
        var resolved = new List<string>();
        foreach (var item in items)
        {
            // Handle array references: ${arrayname[@]}
            var varRefMatch = Regex.Match(item, @"^\$\{(\w+)\[@\]\}$");
            if (varRefMatch.Success)
            {
                var referencedVar = varRefMatch.Groups[1].Value;
                var referencedItems = ParseArray(content, referencedVar, vars);
                resolved.AddRange(ResolveVariableReferences(content, vars, referencedItems));
            }
            else
            {
                var resolvedItem = ResolveString(item, vars);
                resolved.Add(resolvedItem);
            }
        }

        resolved = resolved.Select(dep =>
        {
            // Strip version constraint with unresolved $var reference: "pkg>=$_ver" -> "pkg"
            var cleaned = Regex.Replace(dep, @"(>=|<=|>|<|=)\$[\{]?\w+[\}]?.*$", "");
            if (cleaned == dep)
            {
                // Strip dangling operator: "pkg>=" -> "pkg"
                cleaned = Regex.Replace(dep, @"(>=|<=|>|<|=)$", "");
            }
            if (cleaned != dep)
                System.Console.Error.WriteLine($"[Shelly] Warning: Stripped unresolved version constraint: {dep} -> {cleaned}");
            return cleaned;
        }).ToList();

        return resolved;
    }
}


public class PkgbuildInfo
{
    public string? PkgName { get; set; }
    public string? PkgVer { get; set; }
    public string? PkgRel { get; set; }
    public string? Epoch { get; set; }
    public string? PkgDesc { get; set; }
    public string? Url { get; set; }
    public List<string> License { get; set; } = new();
    public List<string> Arch { get; set; } = new();
    public List<string> Depends { get; set; } = new();
    public List<string> MakeDepends { get; set; } = new();
    public List<string> CheckDepends { get; set; } = new();
    public List<string> OptDepends { get; set; } = new();
    public List<string> Provides { get; set; } = new();
    public List<string> Conflicts { get; set; } = new();
    public List<string> Replaces { get; set; } = new();
    public List<string> Source { get; set; } = new();
    public List<string> Sha256Sums { get; set; } = new();
    public List<string> Sha512Sums { get; set; } = new();
    public List<string> Md5Sums { get; set; } = new();
    public Dictionary<string, string> Variables { get; set; } = new();

    public string? InstallFile { get; set; }

    public string? PostInstall { get; set; }

    public List<string> LocalSourceFiles { get; set; } = new();

    public Dictionary<string, string> LocalSourceContents { get; set; } = new();

    public List<ParsedDependency> ParsedDepends
    {
        get => field.Any() ? field : ParseDependencies(ref field, Depends);
    } = [];

    public List<ParsedDependency> ParsedMakeDepends
    {
        get => field.Any() ? field : ParseDependencies(ref field, MakeDepends);
    } = [];

    public List<ParsedDependency> ParsedCheckDepends
    {
        get => field.Any() ? field : ParseDependencies(ref field, CheckDepends);
    } = [];

    private static List<ParsedDependency> ParseDependencies(ref List<ParsedDependency> storage, List<string> items)
    {
        storage.AddRange(items.Select(ParsedDependency.Parse));
        return storage;
    }


    public List<string> GetAllBuildDependencies(bool includeCheckDepends = false)
    {
        var deps = Depends.Concat(MakeDepends);
        if (includeCheckDepends)
            deps = deps.Concat(CheckDepends);
        return deps.Distinct().ToList();
    }


    public string GetFullVersion()
    {
        var version = PkgVer ?? "0";
        if (!string.IsNullOrEmpty(PkgRel))
            version += $"-{PkgRel}";
        if (!string.IsNullOrEmpty(Epoch))
            version = $"{Epoch}:{version}";
        return version;
    }
}
