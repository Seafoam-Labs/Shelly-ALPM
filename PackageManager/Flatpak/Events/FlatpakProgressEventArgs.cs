using System;

namespace PackageManager.Flatpak.Events;

public class FlatpakProgressEventArgs(string name, string status, int percentage) : EventArgs
{
    public string? Name { get; } = name;
    public string? Status { get; } = status;
    public int? Percentage { get; } = percentage;
}