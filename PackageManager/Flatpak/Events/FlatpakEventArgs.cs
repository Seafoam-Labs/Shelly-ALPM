namespace PackageManager.Flatpak.Events;

public sealed record FlatpakEventArgs(FlatpakEventEnum EventType, string Message);