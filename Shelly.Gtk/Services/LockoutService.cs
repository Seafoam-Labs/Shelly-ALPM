using System.Text.RegularExpressions;

namespace Shelly.Gtk.Services;

public partial class LockoutService : ILockoutService
{
    private static readonly Regex FlatpakProgressPattern =
        FlatpakRegex();

    private static readonly Regex AurProgressPattern =
        AurRegex();

    private static readonly Regex MakepkgStatusPattern =
        MakepkgStatusRegex();

    private static readonly Regex AlpmProgressPattern =
        AlpmRegex();
    
    private static readonly Regex RunningHooksPattern = HooksRegex();
    
    private static readonly Regex BracketPrefixPattern = BracketPrefixRegex();

    private readonly Lock _lock = new();

    public event EventHandler<ILockoutService.LockoutStatusEventArgs>? StatusChanged;
    public event EventHandler<string>? LogLineReceived;

    private bool IsLocked { get; set; }

    private double Progress { get; set; }

    private bool IsIndeterminate { get; set; } = true;

    private string? Description { get; set; }

    public void Show(string description, double progress = 0, bool isIndeterminate = true)
    {
        _stderrLogService ??= new ConsoleLogService(this, true);
        _stderrLogService.Start();

        lock (_lock)
        {
            IsLocked = true;
            Description = description;
            Progress = progress;
            IsIndeterminate = isIndeterminate;
        }
        NotifyChanged();
    }

    private void Update(string? description = null, double? progress = null, bool? isIndeterminate = null)
    {
        lock (_lock)
        {
            if (description != null) Description = description;
            if (progress != null) Progress = progress.Value;
            if (isIndeterminate != null) IsIndeterminate = isIndeterminate.Value;
        }
        NotifyChanged();
    }

    public void Hide()
    {
        lock (_lock)
        {
            IsLocked = false;
        }
        _stderrLogService?.Stop();
        NotifyChanged();
    }
    
    private ConsoleLogService? _stderrLogService;

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
        var cleanedLine = BracketPrefixPattern.Replace(logLine, "");
        if (!string.IsNullOrWhiteSpace(cleanedLine))
        {
            LogLineReceived?.Invoke(this, cleanedLine);
        }

        var matchFlatpak = FlatpakProgressPattern.Match(logLine);
        var matchAur = AurProgressPattern.Match(logLine);
        var matchMakepkg = MakepkgStatusPattern.Match(logLine);
        var matchAlpm = AlpmProgressPattern.Match(logLine);
        var hooksMatch = RunningHooksPattern.Match(logLine);

        if (matchFlatpak.Success)
        {
            if (!double.TryParse(matchFlatpak.Groups[1].Value, out var progress)) return;
            var description = matchFlatpak.Groups[2].Value;
            Update(description, progress, false);
        }
        else if (matchAur.Success)
        {
            var progress = matchAur.Groups[1].Value;
            var description = matchAur.Groups[2].Value;
            Update(description, double.Parse(progress), false);
        }
        else if (matchMakepkg.Success)
        {
            var message = matchMakepkg.Groups[1].Value;
            Update(message, null, true);
        }
        else if (matchAlpm.Success)
        {
            var status = matchAlpm.Groups[1].Value;
            var pkg = matchAlpm.Groups[2].Value;
            if (double.TryParse(matchAlpm.Groups[3].Value, out var progress))
            {
                Update($"{status} {pkg}", progress, false);
            }
        }
        else if (matchMakepkg.Success)
        {
            var status = matchMakepkg.Groups[1].Value;
            Update(status, 100, true);
        }
        else if (hooksMatch.Success)
        {
            Update("Running Hooks", 100, true);
        }
    }

    private void NotifyChanged()
    {
        bool locked;
        double prog;
        bool indet;
        string? desc;

        lock (_lock)
        {
            locked = IsLocked;
            prog = Progress;
            indet = IsIndeterminate;
            desc = Description;
        }

        StatusChanged?.Invoke(this, new ILockoutService.LockoutStatusEventArgs
        {
            IsLocked = locked,
            Description = desc,
            Progress = prog,
            IsIndeterminate = indet
        });
    }

    [GeneratedRegex(@"\[DEBUG_LOG\]\s*Progress:\s*(\d+)%\s*-\s*(.+)", RegexOptions.Compiled)]
    private static partial Regex FlatpakRegex();

    [GeneratedRegex(@"Percent:\s*(\d+)%\s+Message:\s*(.+)", RegexOptions.Compiled)]
    private static partial Regex AurRegex();

    [GeneratedRegex(@"(?:==>|\s+->)\s*(.*)", RegexOptions.Compiled)]
    private static partial Regex MakepkgStatusRegex();

    [GeneratedRegex(@"ALPM Progress: (\w+), Pkg: ([^,]+), %: (\d+)(?:, bytesRead: (\d+), totalBytes: (\d+))?",
        RegexOptions.Compiled)]
    private static partial Regex AlpmRegex();

    [GeneratedRegex(@"(?:\[.*?\]\s*)*Running hooks\.\.\.", RegexOptions.Compiled)]
    private static partial Regex HooksRegex();

    [GeneratedRegex(@"^(\[.*?\]\s*)+", RegexOptions.Compiled)]
    private static partial Regex BracketPrefixRegex();
}