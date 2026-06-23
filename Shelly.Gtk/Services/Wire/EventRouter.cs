using Shelly.Gtk.Helpers;
using Shelly.Gtk.UiModels;
using Shelly.Utilities.Eventing;

namespace Shelly.Gtk.Services.Wire;

internal sealed class EventRouter
{
    private readonly IAlpmEventService? _alpmEventService;
    private readonly ILockoutService? _lockoutService;
    private readonly Dictionary<string, (ProgressType type, int percent)> _lastProgress = new();

    public EventRouter(IAlpmEventService? alpmEventService = null, ILockoutService? lockoutService = null)
    {
        _alpmEventService = alpmEventService;
        _lockoutService = lockoutService;
    }

    private void Log(string line) => _lockoutService?.ParseLog(line);

    public bool TryDispatch(string base64)
    {
        if (!JsonPackFrame.TryDecodePayload<Event>(base64, out var evt) || evt is null)
            return false;

        switch (evt)
        {
            case AlpmErrorEvent e:
                Console.Error.WriteLine($"[ALPM_ERROR] {e.ErrorMessage}");
                Log($"[ERROR] {e.ErrorMessage}");
                break;
            case AlpmHookEvent e:
                Log($"[HOOK] {e.Description}");
                break;
            case AlpmScriptletEvent e:
                Log($"[SCRIPTLET] {e.Line}");
                break;
            case AlpmReplaceEvent e:
                Log($"[REPLACE] {e.Repository}/{e.PackageName} replaces {string.Join(", ", e.Replaces)}");
                break;
            case AlpmPackageProgressEvent e:
                var key = e.PackageName ?? string.Empty;
                if (_lastProgress.TryGetValue(key, out var prev)
                    && prev.type == e.ProgressType
                    && prev.percent == e.Percent)
                    break;
                _lastProgress[key] = (e.ProgressType, e.Percent);
                var label = string.IsNullOrEmpty(e.Message)
                    ? $"{e.PackageName}: {e.Percent}% - {e.ProgressType}"
                    : $"{e.PackageName}: {e.Percent}% - {e.Message}";
                Log($"[PROGRESS] {label}");
                break;
            case AlpmInformationalEvent e:
                var prefix = e.PackageName != null && e.CurrentIndex.HasValue && e.TotalCount.HasValue
                    ? $"[{e.CurrentIndex}/{e.TotalCount}] {e.PackageName}: "
                    : string.Empty;
                Log($"[INFO {e.EventType}] {prefix}{e.Message}");
                break;
            case AlpmStatusEvent e:
                Log($"[STATUS] {e.Status}");
                break;
            case FlatpakProgressEvent e:
                Log($"[PROGRESS] {e.Status} {e.Percentage}%");
                break;
            case FlatpakStatusEvent e:
                Log($"[STATUS] {e.Status}");
                break;
            case AppImageProgressEvent e:
                Log($"[PROGRESS] {e.Status} {e.Percentage}%");
                break;
            case AppImageStatusEvent e:
                var msg = string.IsNullOrEmpty(e.Message) ? e.Status.ToString() : e.Message;
                Log($"[STATUS] {msg}");
                break;
        }
        return true;
    }
}
