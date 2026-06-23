using System.CommandLine;
using System.Text;

namespace Shelly.Cli.Completions;

internal static class CompletionScript
{
    public static string Generate(string shell, RootCommand root, string command) =>
        shell switch
        {
            "fish" => GenerateFish(root, command),
            "zsh" => GenerateZsh(root, command),
            _ => throw new ArgumentException($"Unsupported shell: {shell}. Supported shells: fish, zsh.")
        };

    // --- shared helpers -----------------------------------------------------

    private static bool IsHelpOrVersion(Option option) =>
        option.Name is "--help" or "--version";

    private static IEnumerable<Option> VisibleOptions(Command command) =>
        command.Options.Where(o => !o.Hidden && !IsHelpOrVersion(o));

    private static IEnumerable<Command> VisibleSubcommands(Command command) =>
        command.Subcommands.Where(c => !c.Hidden);

    private static bool RequiresValue(Type valueType)
    {
        var t = Nullable.GetUnderlyingType(valueType) ?? valueType;
        return t != typeof(bool);
    }

    private static string[]? GetChoices(Type valueType)
    {
        var t = Nullable.GetUnderlyingType(valueType) ?? valueType;
        return t.IsEnum ? Enum.GetNames(t) : null;
    }
    

    private static string GenerateFish(RootCommand root, string command)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"# Fish shell completions for {command}");
        sb.AppendLine("# Auto-generated from the Shelly CLI command structure. Do not edit by hand.");
        sb.AppendLine();
        sb.AppendLine($"# Disable file completions by default");
        sb.AppendLine($"complete -c {command} -f");
        sb.AppendLine();

        // Root-level recursive (global) options are available everywhere.
        var rootRecursive = VisibleOptions(root).Where(o => o.Recursive).ToList();
        if (rootRecursive.Count > 0)
        {
            sb.AppendLine("# --- global options ---");
            foreach (var option in rootRecursive)
                sb.AppendLine(FishOptionLine(command, option, condition: null));
            sb.AppendLine();
        }

        WalkFish(root, new List<string>(), command, rootRecursive, sb);
        return sb.ToString();
    }

    private static void WalkFish(
        Command cmd,
        List<string> path,
        string command,
        List<Option> inheritedRecursive,
        StringBuilder sb)
    {
        var subs = VisibleSubcommands(cmd).ToList();

        if (subs.Count > 0)
        {
            string condition = path.Count == 0
                ? "__fish_use_subcommand"
                : $"{SeenCondition(path)}; and not __fish_seen_subcommand_from {string.Join(" ", subs.Select(s => s.Name))}";

            foreach (var sub in subs)
                sb.AppendLine(
                    $"complete -c {command} -n \"{condition}\" -a {sub.Name} -d \"{FishEscape(sub.Description)}\"");
        }

        if (path.Count > 0)
        {
            var seen = SeenCondition(path);
            var options = VisibleOptions(cmd)
                .Concat(inheritedRecursive)
                .GroupBy(o => o.Name)
                .Select(g => g.First());

            foreach (var option in options)
                sb.AppendLine(FishOptionLine(command, option, seen));
        }

        var nextInherited = inheritedRecursive
            .Concat(VisibleOptions(cmd).Where(o => o.Recursive))
            .GroupBy(o => o.Name)
            .Select(g => g.First())
            .ToList();

        foreach (var sub in subs)
        {
            var childPath = new List<string>(path) { sub.Name };
            WalkFish(sub, childPath, command, nextInherited, sb);
        }
    }

    private static string SeenCondition(IReadOnlyList<string> path) =>
        string.Join("; and ", path.Select(p => $"__fish_seen_subcommand_from {p}"));

    private static string FishOptionLine(string command, Option option, string? condition)
    {
        var sb = new StringBuilder();
        sb.Append($"complete -c {command}");
        if (condition is not null)
            sb.Append($" -n \"{condition}\"");

        foreach (var name in OptionNames(option))
        {
            if (name.StartsWith("--", StringComparison.Ordinal))
                sb.Append($" -l {name[2..]}");
            else if (name.StartsWith("-", StringComparison.Ordinal))
                sb.Append($" -s {name[1..]}");
        }

        if (!string.IsNullOrEmpty(option.Description))
            sb.Append($" -d \"{FishEscape(option.Description)}\"");

        if (RequiresValue(option.ValueType))
        {
            sb.Append(" -r");
            var choices = GetChoices(option.ValueType);
            if (choices is { Length: > 0 })
                sb.Append($" -a \"{string.Join(" ", choices)}\"");
        }

        return sb.ToString();
    }

    private static IEnumerable<string> OptionNames(Option option) =>
        new[] { option.Name }.Concat(option.Aliases);

    private static string FishEscape(string? text) =>
        (text ?? string.Empty)
        .Replace("\\", "\\\\")
        .Replace("\"", "'")
        .Replace("\r", " ")
        .Replace("\n", " ");
    

    private static string GenerateZsh(RootCommand root, string command)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"#compdef {command}");
        sb.AppendLine($"# Zsh completions for {command}");
        sb.AppendLine("# Auto-generated from the Shelly CLI command structure. Do not edit by hand.");
        sb.AppendLine();

        var rootRecursive = VisibleOptions(root).Where(o => o.Recursive).ToList();
        WalkZsh(root, new List<string>(), command, rootRecursive, sb);

        sb.AppendLine($"_{command} \"$@\"");
        return sb.ToString();
    }

    private static void WalkZsh(
        Command cmd,
        List<string> path,
        string command,
        List<Option> inheritedRecursive,
        StringBuilder sb)
    {
        var funcName = ZshFunctionName(command, path);
        var subs = VisibleSubcommands(cmd).ToList();

        var options = (path.Count == 0
                ? VisibleOptions(cmd)
                : VisibleOptions(cmd).Concat(inheritedRecursive))
            .GroupBy(o => o.Name)
            .Select(g => g.First())
            .ToList();

        sb.AppendLine($"{funcName}() {{");

        if (subs.Count > 0)
        {
            sb.AppendLine("    local line state");
            sb.AppendLine("    _arguments -C \\");
            foreach (var option in options)
                sb.AppendLine($"        {ZshOptionSpec(option)} \\");
            sb.AppendLine("        '1: :->command' \\");
            sb.AppendLine("        '*:: :->args'");
            sb.AppendLine();
            sb.AppendLine("    case $state in");
            sb.AppendLine("        command)");
            sb.AppendLine("            local -a subcommands");
            sb.AppendLine("            subcommands=(");
            foreach (var sub in subs)
                sb.AppendLine($"                '{sub.Name}:{ZshEscape(sub.Description)}'");
            sb.AppendLine("            )");
            sb.AppendLine("            _describe 'command' subcommands");
            sb.AppendLine("            ;;");
            sb.AppendLine("        args)");
            sb.AppendLine("            case $line[1] in");
            foreach (var sub in subs)
            {
                var childFunc = ZshFunctionName(command, new List<string>(path) { sub.Name });
                sb.AppendLine($"                {sub.Name}) {childFunc} ;;");
            }
            sb.AppendLine("            esac");
            sb.AppendLine("            ;;");
            sb.AppendLine("    esac");
        }
        else if (options.Count > 0)
        {
            sb.AppendLine("    _arguments \\");
            for (var i = 0; i < options.Count; i++)
            {
                var trailer = i == options.Count - 1 ? string.Empty : " \\";
                sb.AppendLine($"        {ZshOptionSpec(options[i])}{trailer}");
            }
        }
        else
        {
            sb.AppendLine("    return 0");
        }

        sb.AppendLine("}");
        sb.AppendLine();

        var nextInherited = inheritedRecursive
            .Concat(VisibleOptions(cmd).Where(o => o.Recursive))
            .GroupBy(o => o.Name)
            .Select(g => g.First())
            .ToList();

        foreach (var sub in subs)
        {
            var childPath = new List<string>(path) { sub.Name };
            WalkZsh(sub, childPath, command, nextInherited, sb);
        }
    }

    private static string ZshFunctionName(string command, IReadOnlyList<string> path) =>
        path.Count == 0
            ? $"_{command}"
            : $"_{command}_" + string.Join("_", path.Select(p => p.Replace('-', '_')));

    private static string ZshOptionSpec(Option option)
    {
        var names = OptionNames(option).ToList();
        var exclusion = "(" + string.Join(" ", names) + ")";
        var nameForm = names.Count > 1
            ? "{" + string.Join(",", names) + "}"
            : names[0];

        var spec = new StringBuilder();
        spec.Append('\'');
        spec.Append(exclusion);
        spec.Append(nameForm);
        spec.Append('[').Append(ZshEscape(option.Description)).Append(']');

        if (RequiresValue(option.ValueType))
        {
            spec.Append(":value:");
            var choices = GetChoices(option.ValueType);
            if (choices is { Length: > 0 })
                spec.Append('(').Append(string.Join(" ", choices)).Append(')');
        }

        spec.Append('\'');
        return spec.ToString();
    }

    private static string ZshEscape(string? text) =>
        (text ?? string.Empty)
        .Replace("'", string.Empty)
        .Replace("[", "(")
        .Replace("]", ")")
        .Replace(":", "\\:")
        .Replace("\r", " ")
        .Replace("\n", " ");
}
