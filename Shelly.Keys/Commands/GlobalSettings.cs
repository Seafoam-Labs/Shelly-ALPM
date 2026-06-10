using System.ComponentModel;
using Spectre.Console.Cli;

namespace Shelly.Keys.Commands;

public class GlobalSettings : CommandSettings
{
    [CommandOption("--keyserver <URL>")]
    [Description("OpenPGP keyserver URL (e.g. hkps://keyserver.ubuntu.com). " +
                 "Persisted to gpg.conf when used with --init; otherwise applied to the current invocation.")]
    public string? Keyserver { get; set; }
    
    [CommandOption("-d | --gpgdir <Directory>")]
    [Description("The directory to initialize the keyring in")]
    //TODO: Change this to a shelly value when/if we remove pacman from a build
    public string Directory { get; set; } = "/etc/pacman.d/gnupg";
    
}