using System;

namespace PackageManager.Alpm;

public class AlpmProgressEventArgs(
    AlpmProgressType progressType,
    string? packageName,
    int? percent,
    ulong? howMany,
    ulong? current,
    string? message = null)
    : EventArgs
{
    public AlpmProgressType ProgressType { get; } = progressType;
    public string? PackageName { get; } = packageName;
    public int? Percent { get; } = percent;
    public ulong? HowMany { get; } = howMany;
    public ulong? Current { get; } = current;
    public string? Message { get; } = message;
}
