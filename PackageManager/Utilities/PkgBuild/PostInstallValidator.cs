using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace PackageManager.Utilities.PkgBuild;

public enum ValidationSeverity
{
    Info,
    Warning,
    Critical
}

public class ValidationFinding
{

    public required string Tool { get; init; }

    public ValidationSeverity Severity { get; init; }

    public required string Hook { get; init; }


    public required string MatchedLine { get; init; }

    public required string Message { get; init; }
}

public class ValidationResult
{
    public bool HasFindings => Findings.Count > 0;

    public List<ValidationFinding> Findings { get; } = new();
}

/// <summary>
/// Inspects the resolved install scriptlets of a PKGBUILD for invocations of
/// package managers / network-fetching tools (npm and similar) that fetch and
/// execute arbitrary code at install time, outside of pacman's control.
///
/// Detection performs lightweight de-obfuscation (collapsing quote-splitting
/// such as <c>b''u''n</c>, intra-word backslash escapes such as <c>cur\l</c>,
/// and quotes embedded in words such as <c>n"p"m</c>) before matching, and
/// flags dynamic command construction (<c>$(...)</c>, backticks, <c>eval</c>,
/// <c>${...}</c> indirection, base64-into-shell pipelines). This is
/// defense-in-depth mitigation, not a guarantee: it is not a shell sandbox and
/// may be bypassed by sufficiently creative shell tricks.
/// </summary>
public class PostInstallValidator
{
    /// <summary>
    /// Tools considered risky when invoked inside an install scriptlet.
    /// Exposed as a settable property so the set can be extended or overridden.
    /// </summary>
    private IReadOnlyList<string> RiskyTools { get; init; } =
    [
        // JavaScript / Node
        "npm", "npx", "yarn", "pnpm", "pnpx", "bun", "node", "deno",
        // Python
        "pip", "pip3", "pipx", "uv", "poetry", "pipenv", "rye",
        "conda", "mamba", "micromamba",
        // Ruby
        "gem",
        // Rust
        "cargo install", "rustup",
        // Go
        "go install",
        // PHP
        "php", "composer",
        // Perl
        "cpan", "cpanm",
        // Haskell
        "cabal install", "stack install",
        // Lua
        "luarocks",
        // Nim
        "nimble install",
        // OCaml
        "opam",
        // Elixir / Erlang
        "mix", "rebar3",
        // C/C++
        "conan", "vcpkg",
        // JVM / Scala / Clojure
        "gradle", "mvn", "sbt", "ant", "lein",
        // .NET
        "dotnet",
        // Swift
        "swift",
        // Julia
        "julia",
        // R
        "Rscript",
        // Downloaders / network tools
        "curl", "wget", "wget2", "aria2c", "lftp", "rsync", "scp", "sftp", "fetch",
        // Containers / orchestration / alternative package managers
        "docker", "podman", "kubectl", "helm", "snap", "flatpak", "appimage",
        // Version managers
        "nvm", "rvm", "rbenv", "pyenv", "gvm", "asdf"
    ];

    public ValidationResult Validate(PkgbuildInfo info)
    {
        var result = new ValidationResult();
        ScanHook(info.PostInstall, "post_install", result);

        foreach (var (fileName, content) in info.LocalSourceContents)
            ScanHook(content, $"source: {fileName}", result);

        return result;
    }

    private void ScanHook(string? scriptlet, string hook, ValidationResult result)
    {
        if (string.IsNullOrWhiteSpace(scriptlet))
            return;

        foreach (var rawLine in scriptlet.Split('\n'))
        {
            var line = StripShellComment(rawLine).Trim();
            if (line.Length == 0)
                continue;

            // De-obfuscated copy used only for matching; the original `line`
            // is reported back to the user so findings show the real text.
            var probe = NormalizeForMatching(line);

            foreach (var tool in RiskyTools)
            {
                // Word-boundary match so "npm" matches `npm i` but not `npmrc`.
                var pattern = $@"(^|[\s;&|`(]){Regex.Escape(tool)}(\s|$)";
                if (!Regex.IsMatch(probe, pattern))
                    continue;

                // If the tool only became visible after de-obfuscation, the
                // author actively hid it — treat that as malicious intent.
                var wasObfuscated = !Regex.IsMatch(line, pattern);
                result.Findings.Add(new ValidationFinding
                {
                    Tool = tool,
                    Hook = hook,
                    Severity = wasObfuscated
                        ? ValidationSeverity.Critical
                        : ValidationSeverity.Warning,
                    MatchedLine = line,
                    Message = wasObfuscated
                        ? $"'{tool}' is invoked in {hook}() via obfuscated shell syntax — "
                          + "the tool name was deliberately hidden, which is a strong sign of malicious intent."
                        : $"'{tool}' is invoked in {hook}() — "
                          + "this fetches/executes external code outside pacman's control."
                });
            }

            ScanDynamicExecution(line, hook, result);
        }
    }

    /// <summary>
    /// Flags dynamic command construction whose effective command cannot be
    /// statically resolved: command substitution (<c>$(...)</c>, backticks),
    /// <c>eval</c>, <c>${...}</c> variable indirection, and decode-into-shell
    /// pipelines (<c>base64 -d | sh</c>, etc.).
    /// </summary>
    private static void ScanDynamicExecution(string line, string hook, ValidationResult result)
    {
        // Critical: command is decoded/computed and piped straight into a shell,
        // or evaluated outright — there is no legitimate reason to do this here.
        var isEvalIntoShell =
            Regex.IsMatch(line, @"(^|[\s;&|`(])eval(\s|$)")
            || Regex.IsMatch(line, @"(base64|xxd|printf|echo)\b[^|]*\|\s*(sh|bash|zsh)\b");

        var hasCommandSubstitution =
            line.Contains("$(") || line.Contains('`');

        // Only bash *indirect* expansion (`${!var}`) is treated as evasive;
        // ordinary parameter expansion such as `${HOME}` is benign and common.
        var hasVariableIndirection = line.Contains("${!");

        if (!isEvalIntoShell && !hasCommandSubstitution && !hasVariableIndirection)
            return;

        result.Findings.Add(new ValidationFinding
        {
            Tool = "<dynamic-command>",
            Hook = hook,
            Severity = isEvalIntoShell
                ? ValidationSeverity.Critical
                : ValidationSeverity.Warning,
            MatchedLine = line,
            Message = isEvalIntoShell
                ? $"Dynamic command execution detected in {hook}() — "
                  + "a command is decoded/evaluated and run at install time, so its real behavior cannot be reviewed."
                : $"Dynamic command construction detected in {hook}() — "
                  + "the effective command is computed at runtime and cannot be statically resolved."
        });
    }

    /// <summary>
    /// Produces a de-obfuscated copy of a line for matching purposes by
    /// collapsing quote-splitting (<c>b''u''n</c>, <c>n"p"m</c>), removing
    /// intra-word backslash escapes (<c>cur\l</c>), and stripping quotes that
    /// sit adjacent to word characters (<c>"bun"</c>, <c>c'u'rl</c>).
    /// </summary>
    private static string NormalizeForMatching(string line)
    {
        var sb = new StringBuilder(line.Length);
        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];

            // Intra-word backslash escape: `\x` -> `x` (preserve `\\` and a
            // trailing line-continuation backslash).
            if (c == '\\' && i + 1 < line.Length)
            {
                var next = line[i + 1];
                if (next != '\\' && !char.IsWhiteSpace(next))
                    continue; // drop the backslash, keep the following char
            }

            // Quote(s) adjacent to a word character are an obfuscation device;
            // drop the whole run so `b''u''n` -> `bun`, `n"p"m` -> `npm`.
            if (c == '\'' || c == '"')
            {
                var prevIsWord = sb.Length > 0 && IsWordChar(sb[sb.Length - 1]);
                var j = i;
                while (j < line.Length && (line[j] == '\'' || line[j] == '"'))
                    j++;
                var nextIsWord = j < line.Length && IsWordChar(line[j]);
                if (prevIsWord || nextIsWord)
                {
                    i = j - 1;
                    continue;
                }
            }

            sb.Append(c);
        }

        return sb.ToString();
    }

    private static bool IsWordChar(char c) => char.IsLetterOrDigit(c) || c == '_';

    /// <summary>
    /// Removes a trailing shell comment from a line, respecting single and
    /// double quotes so `#` inside a string is not treated as a comment.
    /// </summary>
    private static string StripShellComment(string line)
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
}
