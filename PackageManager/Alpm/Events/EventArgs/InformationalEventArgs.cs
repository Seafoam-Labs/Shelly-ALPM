namespace PackageManager.Alpm.Events.EventArgs;

public sealed record InformationalEventArgs(
    AlpmEventType EventType,
    string Message,
    string? PackageName = null,
    int? CurrentIndex = null,
    int? TotalCount = null);