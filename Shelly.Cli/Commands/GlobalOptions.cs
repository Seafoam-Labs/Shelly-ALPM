using System.CommandLine;

namespace Shelly.Cli.Commands;

internal static class GlobalOptions
{
    public static readonly Option<bool> NoConfirm =
        new("--no-confirm", "-n") { Description = "Disable confirmation prompts for all actions", Recursive = true };

    public static readonly Option<bool> UiMode =
        new("--ui-mode", "-U") { Description = "Enable UI mode", Recursive = true };

    public static readonly Option<bool> Json =
        new("--json", "-j") { Description = "Output results in JSON format for scripting.", Recursive = true };

    public static readonly Option<bool> Verbose =
        new("--verbose", "-v") { Description = "Enable verbose logging.", Recursive = true };

    // Per-action no-confirm flags
    public static readonly Option<bool> NoConfirmUpgrade =
        new("--no-confirm-upgrade") { Description = "Skip confirmation for upgrade actions", Recursive = true };

    public static readonly Option<bool> NoConfirmInstall =
        new("--no-confirm-install") { Description = "Skip confirmation for install actions", Recursive = true };

    public static readonly Option<bool> NoConfirmRemove =
        new("--no-confirm-remove") { Description = "Skip confirmation for remove actions", Recursive = true };

    public static readonly Option<bool> NoConfirmDowngrade =
        new("--no-confirm-downgrade") { Description = "Skip confirmation for downgrade actions", Recursive = true };

    public static readonly Option<bool> NoConfirmAurInstall =
        new("--no-confirm-aur-install") { Description = "Skip confirmation for AUR install actions", Recursive = true };

    public static readonly Option<bool> NoConfirmAurRemove =
        new("--no-confirm-aur-remove") { Description = "Skip confirmation for AUR remove actions", Recursive = true };

    public static readonly Option<bool> NoConfirmAurUpgrade =
        new("--no-confirm-aur-upgrade") { Description = "Skip confirmation for AUR upgrade actions", Recursive = true };

    public static readonly Option<bool> NoConfirmFlatpakInstall =
        new("--no-confirm-flatpak-install") { Description = "Skip confirmation for Flatpak install actions", Recursive = true };

    public static readonly Option<bool> NoConfirmFlatpakRemove =
        new("--no-confirm-flatpak-remove") { Description = "Skip confirmation for Flatpak remove actions", Recursive = true };

    public static readonly Option<bool> NoConfirmFlatpakUpgrade =
        new("--no-confirm-flatpak-upgrade") { Description = "Skip confirmation for Flatpak upgrade actions", Recursive = true };

    public static readonly Option<bool> NoConfirmAppImageRemove =
        new("--no-confirm-appimage-remove") { Description = "Skip confirmation for AppImage remove actions", Recursive = true };

    public static readonly Option<bool> NoConfirmAppImageUpgrade =
        new("--no-confirm-appimage-upgrade") { Description = "Skip confirmation for AppImage upgrade actions", Recursive = true };

    public static readonly Option<bool> NoConfirmPurify =
        new("--no-confirm-purify") { Description = "Skip confirmation for purify actions", Recursive = true };

    public static readonly Option<bool> NoConfirmMark =
        new("--no-confirm-mark") { Description = "Skip confirmation for mark actions", Recursive = true };

    public static void AddToRoot(RootCommand root)
    {
        root.Add(NoConfirm);
        root.Add(UiMode);
        root.Add(Json);
        root.Add(Verbose);
        root.Add(NoConfirmUpgrade);
        root.Add(NoConfirmInstall);
        root.Add(NoConfirmRemove);
        root.Add(NoConfirmDowngrade);
        root.Add(NoConfirmAurInstall);
        root.Add(NoConfirmAurRemove);
        root.Add(NoConfirmAurUpgrade);
        root.Add(NoConfirmFlatpakInstall);
        root.Add(NoConfirmFlatpakRemove);
        root.Add(NoConfirmFlatpakUpgrade);
        root.Add(NoConfirmAppImageRemove);
        root.Add(NoConfirmAppImageUpgrade);
        root.Add(NoConfirmPurify);
        root.Add(NoConfirmMark);
    }

    public static void Apply(GlobalSettingsCommand command, ParseResult parseResult)
    {
        command.NoConfirm = parseResult.GetValue(NoConfirm);
        command.UiMode = parseResult.GetValue(UiMode);
        command.JsonOutput = parseResult.GetValue(Json);
        command.Verbose = parseResult.GetValue(Verbose);
        command.NoConfirmUpgrade = parseResult.GetValue(NoConfirmUpgrade);
        command.NoConfirmInstall = parseResult.GetValue(NoConfirmInstall);
        command.NoConfirmRemove = parseResult.GetValue(NoConfirmRemove);
        command.NoConfirmDowngrade = parseResult.GetValue(NoConfirmDowngrade);
        command.NoConfirmAurInstall = parseResult.GetValue(NoConfirmAurInstall);
        command.NoConfirmAurRemove = parseResult.GetValue(NoConfirmAurRemove);
        command.NoConfirmAurUpgrade = parseResult.GetValue(NoConfirmAurUpgrade);
        command.NoConfirmFlatpakInstall = parseResult.GetValue(NoConfirmFlatpakInstall);
        command.NoConfirmFlatpakRemove = parseResult.GetValue(NoConfirmFlatpakRemove);
        command.NoConfirmFlatpakUpgrade = parseResult.GetValue(NoConfirmFlatpakUpgrade);
        command.NoConfirmAppImageRemove = parseResult.GetValue(NoConfirmAppImageRemove);
        command.NoConfirmAppImageUpgrade = parseResult.GetValue(NoConfirmAppImageUpgrade);
        command.NoConfirmPurify = parseResult.GetValue(NoConfirmPurify);
        command.NoConfirmMark = parseResult.GetValue(NoConfirmMark);
    }
}