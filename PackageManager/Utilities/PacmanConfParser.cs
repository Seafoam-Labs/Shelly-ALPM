using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using PackageManager.Alpm;

namespace PackageManager.Utilities;

internal static class PacmanConfParser
{
    internal static PacmanConf Parse(string path = "/etc/pacman.conf")
    {
        var conf = new PacmanConf();
        if (!File.Exists(path)) return conf;

        string currentSection = "";
        Repository? currentRepo = null;

        ParseFile(path, conf, ref currentSection, ref currentRepo);

        if (currentRepo != null)
        {
            conf.Repos.Add(currentRepo);
        }

        return conf;
    }

    private static void ParseFile(string path, PacmanConf conf, ref string currentSection, ref Repository? currentRepo)
    {
        if (!File.Exists(path)) return;

        foreach (var line in File.ReadLines(path))
        {
            var trimmedLine = line.Trim();
            if (string.IsNullOrEmpty(trimmedLine) || trimmedLine.StartsWith('#')) continue;

            if (trimmedLine.StartsWith('[') && trimmedLine.EndsWith(']'))
            {
                if (currentRepo != null)
                {
                    conf.Repos.Add(currentRepo);
                    currentRepo = null;
                }

                currentSection = trimmedLine.Substring(1, trimmedLine.Length - 2);
                if (currentSection != "options")
                {
                    currentRepo = new Repository { Name = currentSection };
                }
                continue;
            }

            var parts = trimmedLine.Split('=', 2);
            var key = parts[0].Trim();
            var value = parts.Length > 1 ? parts[1].Trim() : "";

            if (currentSection == "options")
            {
                if (key.ToLowerInvariant() == "include")
                {
                    ParseFile(value, conf, ref currentSection, ref currentRepo);
                }
                else
                {
                    ParseOption(key, value, conf);
                }
            }
            else if (currentRepo != null)
            {
                ParseRepoOption(key, value, currentRepo, conf, ref currentSection);
            }
        }
    }

    private static void ParseOption(string key, string value, PacmanConf conf)
    {
        switch (key.ToLowerInvariant())
        {
            case "rootdir": conf.RootDirectory = value; break;
            case "dbpath": conf.DbPath = value; break;
            case "cachedir": conf.CacheDir = value; break;
            case "logfile": conf.LogFile = value; break;
            case "gpgdir": conf.GpgDir = value; break;
            case "hookdir": conf.HookDir = value.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList(); break;
            case "holdpkg": conf.HoldPkg = value.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList(); break;
            case "xfercommand":
                if (string.IsNullOrEmpty(conf.TransferCommand)) conf.TransferCommand = value;
                else conf.TransferCommandTwo = value;
                break;
            case "usedelta":
                if (double.TryParse(value, out double delta)) conf.UseDelta = delta;
                break;
            case "architecture": conf.Architecture = value; break;
            case "ignorepkg": conf.IgnorePkg.AddRange(value.Split(' ', StringSplitOptions.RemoveEmptyEntries)); break;
            case "ignoregroup": conf.IgnoreGroup.AddRange(value.Split(' ', StringSplitOptions.RemoveEmptyEntries)); break;
            case "noupgrade": conf.NoUpgrade.AddRange(value.Split(' ', StringSplitOptions.RemoveEmptyEntries)); break;
            case "noextract": conf.NoExtract.AddRange(value.Split(' ', StringSplitOptions.RemoveEmptyEntries)); break;
            case "usesyslog": conf.UseSyslog = true; break;
            case "checkspace": conf.CheckSpace = true; break;
            case "siglevel": conf.SigLevel = ParseSigLevel(value.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList()); break;
            case "localfilesiglevel": conf.LocalFileSigLevel = ParseSigLevel(value.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList()); break;
        }
    }

    private static void ParseRepoOption(string key, string value, Repository repo, PacmanConf conf, ref string currentSection)
    {
        switch (key.ToLowerInvariant())
        {
            case "server":
                repo.Servers.Add(value);
                break;
            case "include":
                var includePath = value;
                if (File.Exists(includePath))
                {
                    // For repositories, Include usually contains a list of servers
                    foreach (var includeLine in File.ReadLines(includePath))
                    {
                        var trimmedInclude = includeLine.Trim();
                        if (string.IsNullOrEmpty(trimmedInclude) || trimmedInclude.StartsWith('#')) continue;

                        var includeParts = trimmedInclude.Split('=', 2);
                        if (includeParts[0].Trim().ToLowerInvariant() == "server")
                        {
                            repo.Servers.Add(includeParts[1].Trim());
                        }
                    }
                }
                break;
        }
    }
    
    private static AlpmSigLevel ParseSigLevel(IEnumerable<string> levels)
    {
        AlpmSigLevel result = AlpmSigLevel.None;

        foreach (var level in levels)
        {
            switch (level.ToLowerInvariant())
            {
                // Package Settings
                case "required":
                case "packagerequired":
                    result |= AlpmSigLevel.Package;
                    break;
                case "optional":
                case "packageoptional":
                    result |= AlpmSigLevel.PackageOptional;
                    break;
                case "packagemarginalok":
                    result |= AlpmSigLevel.PackageMarginalOk;
                    break;
                case "packageunknownok":
                    result |= AlpmSigLevel.PackageUnknownOk;
                    break;

                // Database Settings
                case "databaserequired":
                    result |= AlpmSigLevel.Database;
                    break;
                case "databaseoptional":
                    result |= AlpmSigLevel.DatabaseOptional;
                    break;
                case "databasemarginalok":
                    result |= AlpmSigLevel.DatabaseMarginalOk;
                    break;
                case "databaseunknownok":
                    result |= AlpmSigLevel.DatabaseUnknownOk;
                    break;

                // Meta
                case "never":
                    result = AlpmSigLevel.None;
                    break;
                case "trustall":
                    result |= AlpmSigLevel.PackageUnknownOk | AlpmSigLevel.PackageMarginalOk | AlpmSigLevel.DatabaseUnknownOk | AlpmSigLevel.DatabaseMarginalOk;
                    break;
                case "usedefault":
                    result |= AlpmSigLevel.UseDefault;
                    break;
            }
        }

        return result;
    }
}
