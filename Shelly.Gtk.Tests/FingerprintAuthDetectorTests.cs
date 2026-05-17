using Shelly.Gtk.Services;

namespace Shelly.Gtk.Tests;

[TestFixture]
public class FingerprintAuthDetectorTests
{
    private string _tempDir = null!;
    private string _etc = null!;
    private string _vendor = null!;

    [SetUp]
    public void SetUp()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "shelly-fpd-tests-" + Guid.NewGuid().ToString("N"));
        _etc = Path.Combine(_tempDir, "etc-pam.d");
        _vendor = Path.Combine(_tempDir, "usr-lib-pam.d");
        Directory.CreateDirectory(_etc);
        Directory.CreateDirectory(_vendor);
    }

    [TearDown]
    public void TearDown()
    {
        try { Directory.Delete(_tempDir, true); } catch { }
    }

    private string WriteEtc(string name, string contents)
    {
        var path = Path.Combine(_etc, name);
        File.WriteAllText(path, contents);
        return path;
    }

    private string WriteVendor(string name, string contents)
    {
        var path = Path.Combine(_vendor, name);
        File.WriteAllText(path, contents);
        return path;
    }

    private TestDetector NewDetector(bool serviceActive = false, params string[] services)
    {
        var svc = services.Length > 0
            ? services
            : ["sudo", "sudo-i", "polkit-1", "systemd-run0", "login", "system-auth", "system-login"];
        return new TestDetector([_etc, _vendor], svc, serviceActive);
    }

    [Test]
    public void Detect_ReportsSudoFingerprint_WhenPamFprintdIsActive()
    {
        var sudo = WriteEtc("sudo",
            "#%PAM-1.0\nauth       sufficient   pam_fprintd.so\nauth       include      system-auth\n");

        var result = NewDetector().Detect();

        Assert.That(result.SudoUsesFingerprint, Is.True);
        Assert.That(result.MatchingFiles, Does.Contain(sudo));
    }

    [Test]
    public void Detect_IgnoresCommentedLines()
    {
        WriteEtc("sudo",
            "#%PAM-1.0\n#auth       sufficient   pam_fprintd.so\nauth       include      system-auth\n");

        var result = NewDetector().Detect();

        Assert.That(result.SudoUsesFingerprint, Is.False);
        Assert.That(result.MatchingFiles, Is.Empty);
    }

    [Test]
    public void Detect_ReturnsFalse_WhenNoFprintdLine()
    {
        WriteEtc("sudo",
            "#%PAM-1.0\nauth       include      system-auth\naccount    include      system-auth\n");

        var result = NewDetector().Detect();

        Assert.That(result.SudoUsesFingerprint, Is.False);
        Assert.That(result.MatchingFiles, Is.Empty);
    }

    [Test]
    public void Detect_ReturnsFalse_WhenFileMissing()
    {
        var result = NewDetector().Detect();

        Assert.That(result.SudoUsesFingerprint, Is.False);
        Assert.That(result.MatchingFiles, Is.Empty);
    }

    [Test]
    public void Detect_PolkitOnlyHit_DoesNotFlagSudo()
    {
        var polkit = WriteEtc("polkit-1",
            "#%PAM-1.0\nauth       sufficient   pam_fprintd.so\nauth       include      system-auth\n");

        var result = NewDetector().Detect();

        Assert.That(result.SudoUsesFingerprint, Is.False);
        Assert.That(result.MatchingFiles, Does.Contain(polkit));
    }

    [Test]
    public void Detect_FollowsIncludeIntoSystemAuth_CachyOsShape()
    {
        WriteEtc("sudo",
            "#%PAM-1.0\nauth       include      system-auth\naccount    include      system-auth\nsession    include      system-auth\n");
        var sysAuth = WriteEtc("system-auth",
            "auth       sufficient   pam_fprintd.so\nauth       required     pam_unix.so try_first_pass nullok\n");

        var result = NewDetector().Detect();

        Assert.That(result.SudoUsesFingerprint, Is.True);
        Assert.That(result.MatchingFiles, Does.Contain(sysAuth));
    }

    [Test]
    public void Detect_FollowsSubstack()
    {
        WriteEtc("sudo", "auth       substack     system-auth\n");
        var sysAuth = WriteEtc("system-auth", "auth       sufficient   pam_fprintd.so\n");

        var result = NewDetector().Detect();

        Assert.That(result.SudoUsesFingerprint, Is.True);
        Assert.That(result.MatchingFiles, Does.Contain(sysAuth));
    }

    [Test]
    public void Detect_ReadsVendorPamDir_WhenEtcMissing()
    {
        var vendorPolkit = WriteVendor("polkit-1",
            "auth       sufficient   pam_fprintd.so\nauth       include      system-auth\n");

        var result = NewDetector().Detect();

        Assert.That(result.MatchingFiles, Does.Contain(vendorPolkit));
        Assert.That(result.SudoUsesFingerprint, Is.False);
    }

    [Test]
    public void Detect_HandlesLeadingDashOptionalLines()
    {
        WriteEtc("sudo", "-auth      sufficient   pam_fprintd.so\n");

        var result = NewDetector().Detect();

        Assert.That(result.SudoUsesFingerprint, Is.True);
    }

    [Test]
    public void Detect_FlagsSudoUsage_WhenOnlyServiceIsActive()
    {
        var detector = NewDetector(serviceActive: true);

        var result = detector.Detect();

        Assert.That(result.FprintdServiceRunning, Is.True);
        Assert.That(result.SudoUsesFingerprint, Is.True);
        Assert.That(result.MatchingFiles, Is.Empty);
    }

    private sealed class TestDetector : FingerprintAuthDetector
    {
        private readonly bool _serviceActive;

        public TestDetector(string[] roots, string[] services, bool serviceActive)
            : base(roots, services)
        {
            _serviceActive = serviceActive;
        }

        public override bool FprintdServiceActive() => _serviceActive;
    }
}
