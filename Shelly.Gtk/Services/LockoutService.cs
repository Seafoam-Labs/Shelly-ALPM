using System.Text.RegularExpressions;

namespace Shelly.Gtk.Services;

public partial class LockoutService : ILockoutService
{
    private static readonly Regex FlatpakProgressPattern =
        FlatpakRegex();
    
    private static readonly Regex AurProgressPattern =
        AurRegex();

    public event EventHandler<ILockoutService.LockoutStatusEventArgs>? StatusChanged;

    private bool IsLocked { get; set; }

    private double Progress { get; set; }

    private bool IsIndeterminate { get; set; } = true;

    private string? Description { get; set; }

    public void Show(string description, double progress = 0, bool isIndeterminate = true)
    {
        _consoleLogService ??= new ConsoleLogService(this);
        _consoleLogService.Start();

        IsLocked = true;
        Description = description;
        Progress = progress;
        IsIndeterminate = isIndeterminate;
        NotifyChanged();
    }

    private void Update(string? description = null, double? progress = null, bool? isIndeterminate = null)
    {
        if (description != null) Description = description;
        if (progress != null) Progress = progress.Value;
        if (isIndeterminate != null) IsIndeterminate = isIndeterminate.Value;
        NotifyChanged();
    }

    public void Hide()
    {
        IsLocked = false;
        _consoleLogService?.Stop();
        NotifyChanged();
    }

    private ConsoleLogService? _consoleLogService;

    private class LogObserver(LockoutService service) : IObserver<string?>
    {
        public void OnCompleted() => service.Hide();
        public void OnError(Exception error) => service.Hide();
        public void OnNext(string? value) => service.ParseLog(value);
    }

    public IObserver<string?> GetLogObserver()
    {
        return new LogObserver(this);
    }

    public void ParseLog(string? logLine)
    {
        if (string.IsNullOrEmpty(logLine)) return;

        var match = FlatpakProgressPattern.Match(logLine);
        var matchAur = AurProgressPattern.Match(logLine);

        if (match.Success)
        {
            if (!double.TryParse(match.Groups[1].Value, out var progress)) return;
            var description = match.Groups[2].Value;
            Update(description, progress, false);
        }
        if (matchAur.Success)
        {
            var progress = matchAur.Groups[1].Value;
            var description = matchAur.Groups[2].Value;
            Update(description, double.Parse(progress), false);
        }
      
    }

    private void NotifyChanged()
    {
        StatusChanged?.Invoke(this, new ILockoutService.LockoutStatusEventArgs
        {
            IsLocked = IsLocked,
            Description = Description,
            Progress = Progress,
            IsIndeterminate = IsIndeterminate
        });
    }

    [GeneratedRegex(@"\[DEBUG_LOG\]\s*Progress:\s*(\d+)%\s*-\s*(.+)", RegexOptions.Compiled)]
    private static partial Regex FlatpakRegex();
    [GeneratedRegex(@"Percent:\s*(\d+)%\s+Message:\s*(.+)", RegexOptions.Compiled)]
    private static partial Regex AurRegex();
}