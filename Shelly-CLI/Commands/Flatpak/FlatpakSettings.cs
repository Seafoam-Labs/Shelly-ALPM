using System.ComponentModel;
using System.ComponentModel.DataAnnotations;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public sealed class FlathubSearchSettings : JsonSettings
{
    [CommandArgument(0, "<query>")]
    [Description("Search term to find Flatpak applications on Flathub")]
    public string Query { get; init; } = string.Empty;

    [CommandOption("-l|--limit <N>")]
    [Description("Maximum number of search results to display per page")]
    [DefaultValue(21)]
    public int Limit { get; init; } = 21;

    [CommandOption("-p|--page <N>")]
    [Description("Page number for paginated results (starts at 1)")]
    [DefaultValue(1)]
    public int Page { get; init; } = 1;
}

public class FlatpakPackageSettings : CommandSettings
{
    [CommandArgument(0, "<package>")]
    [Description("Flatpak application ID (e.g., com.spotify.Client)")]
    public string Packages { get; set; } = string.Empty;

    [CommandOption("--user")]
    [Description("Install to user scope instead of system scope")]
    public bool IsUser { get; set; } = false;

    [CommandOption("-r|--remote <remote>")]
    [Description("Remote to install from (e.g., flathub, flathub-beta)")]
    public string? Remote { get; set; }

    [CommandOption("-b|--branch <branch>")]
    [Description("Branch to install (e.g., stable, beta). Defaults to stable")]
    public string? Branch { get; set; }

    [CommandOption("--runtime")]
    [Description("Install as a runtime instead of an application")]
    public bool IsRuntime { get; set; } = false;

    [CommandOption("--remove-unused")]
    [Description("Remove unused dependencies after uninstalling")]
    public bool RemoveUnused { get; set; } = false;
}

public class FlatpakRemoveSettings : CommandSettings
{
    [CommandArgument(0, "<package>")]
    [Description("Flatpak application ID (e.g., com.spotify.Client)")]
    public string Packages { get; set; } = string.Empty;

    [CommandOption("-r|--remove-unused")]
    [Description("Remove unused dependencies after uninstalling")]
    public bool RemoveUnused { get; set; } = false;
    
    [CommandOption("-c|--config")]
    [Description("Removes flatpak configuration for removed app")]
    public bool RemoveConfig { get; set; } = false;
}

public class FlatpakRemoteSettings : CommandSettings
{
    [CommandArgument(0, "<remote>")]
    [Description("Flatpak remote name ID (e.g., flathub)")]
    public string RemoteName { get; set; } = string.Empty;
    
    [CommandOption("-u|--remote-url <remote-url>")]
    [Required]
    public string RemoteUrl { get; set; } = string.Empty;

    [CommandOption("-s|--system <true|false>")]
    public bool SystemWide { get; set; } = true;
    
    [CommandOption("-g|--gpg-verify <true|false>")]
    public bool GpgVerify { get; set; } = true;
}

public class FlatpakRemoveRemoteSettings : CommandSettings
{
    [CommandArgument(0, "<remote>")]
    [Description("Flatpak remote name ID (e.g., flathub)")]
    public string RemoteName { get; set; } = string.Empty;

    [CommandOption("-s|--system <true|false>")]
    [Required]
    public bool SystemWide { get; set; } = true;

}

public class FlatpakListRemoteAppStreamSettings : CommandSettings
{
    [CommandArgument(0, "<query>")]
    [Description("Gets appstream data in json (use all to retreive all appstreams)")]
    public string AppStreamName { get; init; } = string.Empty;
}

public class FlatpakRemoteRefFileInstallSettings : CommandSettings
{
    [CommandArgument(0, "<RefFilePath>")]
    [Description("Path to the ref file")]
    public string RefFilePath { get; init; } = string.Empty;
    
    [CommandOption("-s|--system <true|false>")]
    public bool SystemWide { get; set; } = true;
}

public class FlatpakBundleInstallSettings : CommandSettings
{
    [CommandArgument(0, "<BundlePath>")]
    [Description("Path to the .flatpak bundle file")]
    public string BundlePath { get; init; } = string.Empty;

    [CommandOption("-s|--system <true|false>")]
    public bool SystemWide { get; set; } = true;
}


