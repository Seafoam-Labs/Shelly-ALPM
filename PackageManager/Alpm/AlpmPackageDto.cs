using System;
using System.Collections.Generic;
using PackageManager.Alpm.Package;

namespace PackageManager.Alpm;

public record AlpmPackageDto
{
    public string Name { get; init; } = string.Empty;

    public string Version { get; init; } = string.Empty;

    public long Size { get; init; }

    public string Description { get; init; } = string.Empty;

    public string Url { get; init; } = string.Empty;

    public string Repository { get; init; } = string.Empty;

    public List<string> Replaces { get; init; } = [];

    public List<string> Licenses { get; init; } = [];

    public List<string> Groups { get; init; } = [];

    public List<string> Provides { get; init; } = [];

    public List<string> Depends { get; init; } = [];

    public List<string> OptDepends { get; init; } = [];

    public List<string> Conflicts { get; init; } = [];

    public AlpmPackageTreeDto? PackageFile { get; init; } = null;

    public string InstallReason { get; init; } = string.Empty;

    public DateTime? InstallDate { get; init; } = null;

    public DateTime BuildDate { get; init; } = DateTime.MinValue;

    public long DownloadSize { get; init; } = 0;

    public long InstalledSize { get; init; } = 0;

    public List<string> RequiredBy { get; init; } = [];

    public List<string> OptionalFor { get; init; } = [];
}
