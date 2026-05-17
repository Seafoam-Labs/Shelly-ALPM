using System.ComponentModel;
using Spectre.Console.Cli;
using PackageManager.AppImage;

namespace Shelly_CLI.Commands.AppImage;

public class AppImageDefaultSettings : CommandSettings
{
    [CommandOption("-j|--json")]
    [Description("Json output")]
    public bool Json { get; set; }
}

public class AppImageSettings : CommandSettings
{
    [CommandOption("-l | --location")]
    [Description("Location of the .AppImage to be installed")]
    public string? PackageLocation { get; set; }

    [CommandOption("-n|--no-confirm")]
    [Description("Proceed without asking for user confirmation")]
    public bool NoConfirm { get; set; }

    [CommandOption("-u|--update-url")]
    [Description("Set the release URL for update checking (e.g., https://github.com/owner/repo/releases)")]
    public string? UpdateUrl { get; set; } = "";

    [CommandOption("-t|--type")]
    [Description("Set the update type (None, StaticUrl, GitHub, GitLab, Codeberg, Forgejo)")]
    public UpdateType UpdateType { get; set; } = UpdateType.None;
}

public class AppImageRemoveSettings : CommandSettings
{
    [CommandArgument(0, "<Name>")]
    [Description("Name of the AppImage to be removed")]
    public string? Name { get; set; }

    [CommandOption("-n|--no-confirm")]
    [Description("Proceed without asking for user confirmation")]
    public bool NoConfirm { get; set; }
}

public class AppImageConfigUpdatesSettings : CommandSettings
{
    [CommandArgument(0, "<Name>")]
    [Description("Name of the AppImage to configure")]
    public string Name { get; set; } = string.Empty;

    [CommandOption("-u|--update-url")]
    [Description("Set the update URL (e.g., https://github.com/owner/repo)")]
    public string? UpdateUrl { get; set; }

    [CommandOption("-t|--type")]
    [Description("Set the update type (None, StaticUrl, GitHub, GitLab, Codeberg, Forgejo)")]
    public UpdateType UpdateType { get; set; } = UpdateType.StaticUrl;
}

public class AppImageSearchSettings : AppImageDefaultSettings
{
    [CommandArgument(0, "[QUERY]")]
    [Description("The search query for the AppImage")]
    public string? Query { get; set; }
}

public class AppImageSyncMetaSettings : AppImageDefaultSettings
{
    [CommandArgument(0, "[QUERY]")]
    [Description("The search query for the AppImage")]
    public string? Query { get; set; } = "";

    [CommandOption("-n|--no-confirm")]
    [Description("Proceed without asking for user confirmation")]
    public bool NoConfirm { get; set; }
}

public class AppImageUpdateSettings : CommandSettings
{
    [CommandArgument(0, "[Name]")]
    [Description("Name of the AppImage to update. If omitted, all available updates will be processed.")]
    public string? Name { get; set; }

    [CommandOption("-n|--no-confirm")]
    [Description("Proceed without asking for user confirmation")]
    public bool NoConfirm { get; set; }
}