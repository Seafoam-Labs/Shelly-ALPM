namespace Shelly.Gtk.Services;

public interface IFingerprintAuthState
{
    FingerprintDetectionResult Current { get; }
    bool ShouldWarn { get; }
    string GetHintMessage();
    void Refresh();
}

public class FingerprintAuthState : IFingerprintAuthState
{
    private readonly IFingerprintAuthDetector _detector;
    private readonly IConfigService _configService;
    private readonly object _gate = new();
    private FingerprintDetectionResult? _cached;

    public FingerprintAuthState(IFingerprintAuthDetector detector, IConfigService configService)
    {
        _detector = detector;
        _configService = configService;
    }

    public FingerprintDetectionResult Current
    {
        get
        {
            lock (_gate)
            {
                _cached ??= _detector.Detect();
                return _cached;
            }
        }
    }

    public bool ShouldWarn
    {
        get
        {
            try
            {
                if (!HasDisplay()) return false;
                var cfg = _configService.LoadConfig();
                if (cfg.SuppressFingerprintWarning) return false;
                var c = Current;
                return c.SudoUsesFingerprint || c.FprintdServiceRunning;
            }
            catch
            {
                return false;
            }
        }
    }

    public string GetHintMessage()
    {
        return "Tip: a fingerprint prompt on sudo (pam_fprintd) may be interfering with privileged output. " +
               "Work for enabling full biometric support is on going please disable for the time being. ";
    }

    public void Refresh()
    {
        lock (_gate)
        {
            _cached = _detector.Detect();
        }
    }

    private static bool HasDisplay()
    {
        var d = Environment.GetEnvironmentVariable("DISPLAY");
        var w = Environment.GetEnvironmentVariable("WAYLAND_DISPLAY");
        return !string.IsNullOrEmpty(d) || !string.IsNullOrEmpty(w);
    }
}
