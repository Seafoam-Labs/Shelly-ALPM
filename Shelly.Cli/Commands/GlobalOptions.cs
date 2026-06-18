using System.CommandLine;

namespace Shelly.Cli.Commands;

internal static class GlobalOptions
{
    public static readonly Option<bool> NoConfirm =
        new("--no-confirm", "-n") { Description = "Disable confirmation prompts", Recursive = true };

    public static readonly Option<bool> UiMode =
        new("--ui-mode", "-U") { Description = "Enable UI mode", Recursive = true };

    public static readonly Option<bool> Json =
        new("--json", "-j") { Description = "Output results in JSON format for scripting.", Recursive = true };

    public static readonly Option<bool> Verbose =
        new("--verbose", "-v") { Description = "Enable verbose logging.", Recursive = true };

    public static void AddToRoot(RootCommand root)
    {
        root.Add(NoConfirm);
        root.Add(UiMode);
        root.Add(Json);
        root.Add(Verbose);
    }

    public static void Apply(GlobalSettingsCommand command, ParseResult parseResult)
    {
        command.NoConfirm = parseResult.GetValue(NoConfirm);
        command.UiMode = parseResult.GetValue(UiMode);
        command.JsonOutput = parseResult.GetValue(Json);
        command.Verbose = parseResult.GetValue(Verbose);
    }
}
