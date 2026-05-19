using System;

namespace PackageManager.Local;

public sealed class LocalManagerMessageEventArgs(
    LocalManagerMessageLevel level,
    string message
) : EventArgs
{
    public LocalManagerMessageLevel Level { get; } = level;
    public string Message { get; } = message;
}