using Shelly.Gtk.Windows;

namespace Shelly.Gtk.Tests;

[TestFixture]
public class AppImageTests
{
    private string _tempDir = null!;

    [SetUp]
    public void SetUp()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "shelly-appimage-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tempDir);
    }

    [TearDown]
    public void TearDown()
    {
        try { Directory.Delete(_tempDir, true); } catch { }
    }

    [Test]
    public void NeedsMigration_ReturnsFalse_WhenLegacyDirectoryDoesNotExist()
    {
        var installDir = Path.Combine(_tempDir, "missing");
        var databasePath = Path.Combine(_tempDir, "missing.db");

        Assert.That(AppImage.NeedsMigration(installDir, databasePath), Is.False);
    }

    [Test]
    public void NeedsMigration_ReturnsTrue_WhenLegacyDirectoryContainsFile()
    {
        var installDir = Path.Combine(_tempDir, "legacy");
        Directory.CreateDirectory(installDir);
        File.WriteAllText(Path.Combine(installDir, "example.AppImage"), "");

        Assert.That(AppImage.NeedsMigration(installDir, Path.Combine(_tempDir, "missing.db")), Is.True);
    }

    [Test]
    public void NeedsMigration_ReturnsTrue_WhenLegacyDatabaseExists()
    {
        var databasePath = Path.Combine(_tempDir, "appimage-metadata.db");
        File.WriteAllText(databasePath, "[]");

        Assert.That(AppImage.NeedsMigration(Path.Combine(_tempDir, "missing"), databasePath), Is.True);
    }
}
