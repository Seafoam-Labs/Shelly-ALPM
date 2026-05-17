using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Tests;

[TestFixture]
public class FingerprintAuthStateTests
{
    private string? _origDisplay;
    private string? _origWayland;

    [SetUp]
    public void SetUp()
    {
        _origDisplay = Environment.GetEnvironmentVariable("DISPLAY");
        _origWayland = Environment.GetEnvironmentVariable("WAYLAND_DISPLAY");
        Environment.SetEnvironmentVariable("DISPLAY", ":0");
        Environment.SetEnvironmentVariable("WAYLAND_DISPLAY", null);
    }

    [TearDown]
    public void TearDown()
    {
        Environment.SetEnvironmentVariable("DISPLAY", _origDisplay);
        Environment.SetEnvironmentVariable("WAYLAND_DISPLAY", _origWayland);
    }

    [Test]
    public void Current_CachesResultAcrossCalls()
    {
        var detector = new CountingDetector(new FingerprintDetectionResult(true, false, []));
        var config = new FakeConfigService(new ShellyConfig());
        var state = new FingerprintAuthState(detector, config);

        _ = state.Current;
        _ = state.Current;
        _ = state.Current;

        Assert.That(detector.CallCount, Is.EqualTo(1));
    }

    [Test]
    public void Refresh_ReevaluatesDetector()
    {
        var detector = new CountingDetector(new FingerprintDetectionResult(false, false, []));
        var config = new FakeConfigService(new ShellyConfig());
        var state = new FingerprintAuthState(detector, config);

        _ = state.Current;
        state.Refresh();
        _ = state.Current;

        Assert.That(detector.CallCount, Is.EqualTo(2));
    }

    [Test]
    public void ShouldWarn_True_WhenSudoUsesFingerprintAndNotSuppressed()
    {
        var detector = new CountingDetector(new FingerprintDetectionResult(true, false, []));
        var config = new FakeConfigService(new ShellyConfig { SuppressFingerprintWarning = false });
        var state = new FingerprintAuthState(detector, config);

        Assert.That(state.ShouldWarn, Is.True);
    }

    [Test]
    public void ShouldWarn_True_WhenServiceRunningOnly()
    {
        var detector = new CountingDetector(new FingerprintDetectionResult(false, true, []));
        var config = new FakeConfigService(new ShellyConfig { SuppressFingerprintWarning = false });
        var state = new FingerprintAuthState(detector, config);

        Assert.That(state.ShouldWarn, Is.True);
    }

    [Test]
    public void ShouldWarn_False_WhenSuppressed()
    {
        var detector = new CountingDetector(new FingerprintDetectionResult(true, true, []));
        var config = new FakeConfigService(new ShellyConfig { SuppressFingerprintWarning = true });
        var state = new FingerprintAuthState(detector, config);

        Assert.That(state.ShouldWarn, Is.False);
    }

    [Test]
    public void ShouldWarn_False_WhenNoDisplay()
    {
        Environment.SetEnvironmentVariable("DISPLAY", null);
        Environment.SetEnvironmentVariable("WAYLAND_DISPLAY", null);

        var detector = new CountingDetector(new FingerprintDetectionResult(true, true, []));
        var config = new FakeConfigService(new ShellyConfig { SuppressFingerprintWarning = false });
        var state = new FingerprintAuthState(detector, config);

        Assert.That(state.ShouldWarn, Is.False);
    }

    [Test]
    public void ShouldWarn_False_WhenNothingDetected()
    {
        var detector = new CountingDetector(new FingerprintDetectionResult(false, false, []));
        var config = new FakeConfigService(new ShellyConfig { SuppressFingerprintWarning = false });
        var state = new FingerprintAuthState(detector, config);

        Assert.That(state.ShouldWarn, Is.False);
    }

    [Test]
    public void GetHintMessage_ReferencesIssue728()
    {
        var detector = new CountingDetector(new FingerprintDetectionResult(false, false, []));
        var config = new FakeConfigService(new ShellyConfig());
        var state = new FingerprintAuthState(detector, config);

        Assert.That(state.GetHintMessage(), Does.Contain("Tip:"));
    }

    private sealed class CountingDetector : IFingerprintAuthDetector
    {
        private readonly FingerprintDetectionResult _result;
        public int CallCount;

        public CountingDetector(FingerprintDetectionResult result) => _result = result;

        public FingerprintDetectionResult Detect()
        {
            CallCount++;
            return _result;
        }

        public bool FprintdServiceActive() => _result.FprintdServiceRunning;
    }

    private sealed class FakeConfigService : IConfigService
    {
        private ShellyConfig _config;
        public FakeConfigService(ShellyConfig config) => _config = config;
        public void SaveConfig(ShellyConfig config) => _config = config;
        public ShellyConfig LoadConfig() => _config;
        public event EventHandler<ShellyConfig>? ConfigSaved;
    }
}
