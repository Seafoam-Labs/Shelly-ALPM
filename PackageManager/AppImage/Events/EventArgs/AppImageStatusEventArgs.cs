namespace PackageManager.AppImage.Events.EventArgs;
using Shelly.Utilities.Eventing;

public class AppImageStatusEventArgs(AppImageEvents severity, string message) : System.EventArgs
{
    public AppImageEvents Severity { get; } = severity;
    public string Message { get; } = message;
}
