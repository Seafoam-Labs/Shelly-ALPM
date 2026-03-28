namespace Shelly.Gtk.Services;

public interface ILockoutService
{
    event EventHandler<LockoutStatusEventArgs>? StatusChanged;
    event EventHandler<string>? LogLineReceived;

    void Show(string description, double progress = 0, bool isIndeterminate = true);
    void Hide();
    void ParseLog(string? logLine);

    public class LockoutStatusEventArgs : EventArgs
    {
        public bool IsLocked { get; init; }
        public double Progress { get; init; }
        public bool IsIndeterminate { get; init; }
        public string? Description { get; init; }
    }

}
