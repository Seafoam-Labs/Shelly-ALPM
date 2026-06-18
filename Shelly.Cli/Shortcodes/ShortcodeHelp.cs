using System.Text;

namespace Shelly.Cli.Shortcodes;

public static class ShortcodeHelp
{
    public static string BuildHelpSection()
    {
        var builder = new StringBuilder();

        builder.AppendLine("Shortcodes:");
        builder.AppendLine("  Grammar: -<Type><Action><modifiers...> [positionals]");
        builder.AppendLine("  Type selects the command group, Action selects the verb, and");
        builder.AppendLine("  modifiers are that verb's own short flags (case-sensitive).");
        builder.AppendLine();
        builder.AppendLine("  Types:");

        foreach (var (letter, group) in ShortcodeMaps.Types)
        {
            var name = string.IsNullOrEmpty(group) ? letter switch { 'S' => "standard", 'U' => "utility", _ => group } : group;
            builder.AppendLine($"    {letter}  {name}");
        }

        builder.AppendLine();
        builder.AppendLine("  Examples:");
        builder.AppendLine("    -SIu firefox   ->  install -u firefox");
        builder.AppendLine("    -AS query      ->  aur search query");
        builder.AppendLine("    -KV ABCD       ->  keyring recv ABCD");
        builder.AppendLine();
        builder.AppendLine("  In shortcode mode use --ui-mode instead of -U.");

        return builder.ToString();
    }
}
