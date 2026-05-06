using System.Collections.Generic;
using System.IO;
using System.Linq;
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
        return ParseContent(pkgbuildContent);
    }
    
    public static PkgbuildInfo ParseContent(string pkgbuildContent)
    {
        var vars = BuildVariableDictionary(pkgbuildContent);
        ScanPrepareForLiteralAssignments(pkgbuildContent, vars);

        return new PkgbuildInfo
        {
            Variables = new Dictionary<string, string>(vars),
            PkgName = ResolveOrParse(pkgbuildContent, vars, "pkgname"),
            PkgVer = ResolveOrParse(pkgbuildContent, vars, "pkgver"),
            PkgRel = ResolveOrParse(pkgbuildContent, vars, "pkgrel"),
            Epoch = ResolveOrParse(pkgbuildContent, vars, "epoch"),
            PkgDesc = ResolveOrParse(pkgbuildContent, vars, "pkgdesc"),
            Url = ResolveOrParse(pkgbuildContent, vars, "url"),
            License = ParseArray(pkgbuildContent, "license"),
            Arch = ParseArray(pkgbuildContent, "arch"),
            Depends = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "depends")),
            MakeDepends = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "makedepends")),
            CheckDepends = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "checkdepends")),
            OptDepends = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "optdepends")),
            Provides = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "provides")),
            Conflicts = ParseArray(pkgbuildContent, "conflicts"),
            Replaces = ParseArray(pkgbuildContent, "replaces"),
            Source = ResolveVariableReferences(pkgbuildContent, vars, ParseArray(pkgbuildContent, "source")),
            Sha256Sums = ParseArray(pkgbuildContent, "sha256sums"),
            Sha512Sums = ParseArray(pkgbuildContent, "sha512sums"),
            Md5Sums = ParseArray(pkgbuildContent, "md5sums"),
        };
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


        result = Regex.Replace(result, @"\$\{(\w+)\}|\$(\w+)", match =>
        {
            var varName = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
            return vars.TryGetValue(varName, out var val) ? val : match.Value;
        });

        return result;
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


    private static List<string> ParseArray(string content, string variableName)
    {
        var result = new List<string>();

        // Match both: varname=(...) and varname+=(...)
        var pattern = $@"^{Regex.Escape(variableName)}\+?=\(([^)]*)\)";
        var matches = Regex.Matches(content, pattern, RegexOptions.Multiline | RegexOptions.Singleline);

        foreach (Match match in matches)
        {
            // Check if this match is inside a conditional block
            if (IsInsideConditionalBlock(content, match.Index))
            {
                System.Console.Error.WriteLine(
                    $"[Shelly] Skipping conditional {variableName}+=() at offset {match.Index}");
                continue;
            }

            var arrayContent = match.Groups[1].Value;


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
                var referencedItems = ParseArray(content, referencedVar);
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
