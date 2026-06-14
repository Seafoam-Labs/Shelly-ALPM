using System.Collections.Generic;
using PackageManager.Alpm;

namespace PackageManager.Utilities;

internal record PacmanConf
{
    public string RootDirectory { get; set; } = "/";
    public string DbPath { get; set; } = "/var/lib/pacman";
    public string CacheDir { get; set; } = "/var/cache/pacman/pkg";
    public string LogFile { get; set; } = "/var/log/pacman.log";
    public string GpgDir { get; set; } = "/etc/pacman.d/gnupg";
    public List<string> HookDir { get; set; } = ["/etc/pacman.d/hooks"];
    public List<string> HoldPkg { get; set; } = ["pacman", "glibc"];
    public string TransferCommand { get; set; } = "/usr/bin/curl -L -C - -f -o %o %u";
    public string TransferCommandTwo { get; set; } = "/usr/bin/wget --passive-ftp -c -O %o %u";
    public double UseDelta { get; set; } = 0.7;
    public string Architecture { get; set; } = "auto";
    public List<string> IgnorePkg { get; set; } = [];
    public List<string> IgnoreGroup { get; set; } = [];
    public List<string> NoUpgrade { get; set; } = [];
    public List<string> NoExtract { get; set; } = [];
    public bool UseSyslog { get; set; } = false;
    public bool CheckSpace { get; set; } = false;
    public List<Repository> Repos { get; set; } = [];
    public AlpmSigLevel SigLevel { get; set; } = AlpmSigLevel.Package | AlpmSigLevel.DatabaseOptional;
    public AlpmSigLevel LocalFileSigLevel { get; set; } = AlpmSigLevel.PackageOptional | AlpmSigLevel.DatabaseOptional;
    public AlpmSigLevel RemoteFileSigLevel { get; set; } = AlpmSigLevel.Package | AlpmSigLevel.Database;
}

internal class Repository
{
    public string Name { get; set; } = string.Empty;
    public List<string> Servers { get; set; } = [];

    public AlpmSigLevel SigLevel { get; set; } = AlpmSigLevel.UseDefault;
}
