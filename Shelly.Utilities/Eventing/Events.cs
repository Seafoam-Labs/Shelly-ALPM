using System;
using System.Text.Json.Serialization;


namespace Shelly.Utilities.Eventing;

[JsonPolymorphic(TypeDiscriminatorPropertyName = "$kind")]
[JsonDerivedType(typeof(AlpmErrorEvent), "alpm.error")]
[JsonDerivedType(typeof(AlpmHookEvent), "alpm.hook")]
[JsonDerivedType(typeof(AlpmScriptletEvent), "alpm.scriptlet")]
[JsonDerivedType(typeof(AlpmReplaceEvent), "alpm.replace")]
[JsonDerivedType(typeof(AlpmPackageProgressEvent), "alpm.progress")]
[JsonDerivedType(typeof(AlpmStatusEvent), "alpm.status")]
[JsonDerivedType(typeof(AlpmInformationalEvent), "alpm.info")]
[JsonDerivedType(typeof(FlatpakStatusEvent), "flatpak.status")]
[JsonDerivedType(typeof(FlatpakProgressEvent), "flatpak.progress")]
[JsonDerivedType(typeof(AppImageStatusEvent), "appimage.status")]
[JsonDerivedType(typeof(AppImageProgressEvent), "appimage.progress")]
public abstract record Event(EventSource Source, EventLevel Level, DateTimeOffset TimeStamp = default)
{
    public DateTimeOffset TimeStamp { get; init; } = TimeStamp == default ? DateTimeOffset.Now : TimeStamp;
}

public sealed record AlpmErrorEvent(EventLevel Level, string ErrorMessage, DateTimeOffset TimeStamp = default)
    : Event(EventSource.Alpm, Level, TimeStamp);

public sealed record AlpmHookEvent(EventLevel Level, string Description, DateTimeOffset TimeStamp = default)
    : Event(EventSource.Alpm, Level, TimeStamp);

public sealed record AlpmScriptletEvent(EventLevel Level, string Line, DateTimeOffset TimeStamp = default)
    : Event(EventSource.Alpm, Level, TimeStamp);

public sealed record AlpmReplaceEvent(
    string Repository,
    string PackageName,
    List<string> Replaces,
    DateTimeOffset TimeStamp = default) : Event(EventSource.Alpm, EventLevel.Information, TimeStamp);

public abstract record ProgressEvent(
    EventSource Source,
    ProgressType ProgressType,
    int Percent,
    DateTimeOffset TimeStamp = default)
    : Event(Source, EventLevel.Information, TimeStamp);

public sealed record AlpmPackageProgressEvent(
    string PackageName,
    ulong CurrentDownload,
    ulong TotalDownload,
    ProgressType ProgressType,
    int Percent,
    string? Message,
    DateTimeOffset TimeStamp = default)
    : ProgressEvent(EventSource.Alpm, ProgressType, Percent, TimeStamp);

public sealed record AlpmStatusEvent(string Status, DateTimeOffset TimeStamp = default)
    : Event(EventSource.Alpm, EventLevel.Information, TimeStamp);

public sealed record AlpmInformationalEvent(
    AlpmEvents EventType,
    string Message,
    string? PackageName = null,
    int? CurrentIndex = null,
    int? TotalCount = null,
    DateTimeOffset TimeStamp = default)
    : Event(EventSource.Alpm, EventLevel.Information, TimeStamp);

public sealed record FlatpakStatusEvent(FlatpakEvents Status, string? Message, DateTimeOffset TimeStamp = default)
    : Event(EventSource.Flatpak, EventLevel.Information, TimeStamp);

public sealed record FlatpakProgressEvent(
    string? Status,
    int? Percentage,
    DateTimeOffset TimeStamp = default)
    : Event(EventSource.Flatpak, EventLevel.Information, TimeStamp);
    
public sealed record AppImageStatusEvent(AppImageEvents Status, string? Message, DateTimeOffset TimeStamp = default)
    : Event(EventSource.AppImage, EventLevel.Information, TimeStamp);

public sealed record AppImageProgressEvent(
    string? Status,
    int? Percentage,
    DateTimeOffset TimeStamp = default)
    : Event(EventSource.AppImage, EventLevel.Information, TimeStamp);