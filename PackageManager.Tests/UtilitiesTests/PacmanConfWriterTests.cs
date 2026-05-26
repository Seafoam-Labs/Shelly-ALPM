using System.Text.RegularExpressions;
using PackageManager.Utilities;

namespace PackageManager.Tests.UtilitiesTests;

[TestFixture]
[TestOf(typeof(PacmanConfWriter))]
public class PacmanConfWriterTests
{
    [SetUp]
    public void SetUp()
    {
        _tempPath = Path.GetTempFileName();
    }

    [TearDown]
    public void TearDown()
    {
        File.Delete(_tempPath);
    }

    private string _tempPath = null!;

    private static PacmanConf EmptyConf()
    {
        return new PacmanConf { IgnorePkg = [] };
    }

    private void WriteConfig(string content)
    {
        File.WriteAllText(_tempPath, content);
    }

    private string ReadConfig()
    {
        return File.ReadAllText(_tempPath);
    }

    [Test]
    public void AddIgnorePkg_WritesEntryIntoExistingOptionsSection()
    {
        WriteConfig("[options]\nColor\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n");
        var conf = EmptyConf();

        PacmanConfWriter.AddIgnorePkg(conf, "vim", _tempPath);

        Assert.Multiple(() =>
        {
            Assert.That(ReadConfig(), Does.Contain("IgnorePkg = vim"));
            Assert.That(conf.IgnorePkg, Does.Contain("vim"));
        });
    }

    [Test]
    public void AddIgnorePkg_AppendsToExistingIgnorePkgLine()
    {
        WriteConfig("[options]\nIgnorePkg = git\n");
        var conf = new PacmanConf { IgnorePkg = ["git"] };

        PacmanConfWriter.AddIgnorePkg(conf, "vim", _tempPath);

        Assert.That(ReadConfig(), Does.Contain("IgnorePkg = git vim"));
    }

    [Test]
    public void AddIgnorePkg_IsIdempotent_WhenPackageAlreadyPresent()
    {
        WriteConfig("[options]\nIgnorePkg = vim\n");
        var conf = new PacmanConf { IgnorePkg = ["vim"] };

        PacmanConfWriter.AddIgnorePkg(conf, "vim", _tempPath);

        var occurrences = ReadConfig().Split('\n').Count(l => l.Contains("IgnorePkg"));
        Assert.That(occurrences, Is.EqualTo(1));
    }

    [Test]
    public void AddIgnorePkg_CreatesOptionsSectionWhenMissing()
    {
        WriteConfig("[core]\nInclude = /etc/pacman.d/mirrorlist\n");
        var conf = EmptyConf();

        PacmanConfWriter.AddIgnorePkg(conf, "vim", _tempPath);

        var content = ReadConfig();
        Assert.That(content, Does.Contain("[options]"));
        Assert.That(content, Does.Contain("IgnorePkg = vim"));
    }

    [Test]
    public void AddIgnorePkg_UncommentsCommentedIgnorePkgLine()
    {
        WriteConfig("[options]\n#IgnorePkg = git\n");
        var conf = new PacmanConf { IgnorePkg = ["git"] };

        PacmanConfWriter.AddIgnorePkg(conf, "vim", _tempPath);

        var content = ReadConfig();
        Assert.That(content, Does.Not.Contain("#IgnorePkg"));
        Assert.That(content, Does.Contain("IgnorePkg = git vim"));
    }

    [TestCase("  ")]
    [TestCase("")]
    public void AddIgnorePkg_ThrowsOnNullOrWhiteSpace(string packageName)
    {
        WriteConfig("[options]\n");
        var conf = EmptyConf();

        Assert.That(() => PacmanConfWriter.AddIgnorePkg(conf, packageName, _tempPath),
            Throws.ArgumentException);
    }

    [Test]
    public void RemoveIgnorePkg_RemovesOnlyTargetPackage()
    {
        WriteConfig("[options]\nIgnorePkg = git vim curl\n");
        var conf = new PacmanConf { IgnorePkg = ["git", "vim", "curl"] };

        PacmanConfWriter.RemoveIgnorePkg(conf, "vim", _tempPath);

        var content = ReadConfig();
        Assert.That(content, Does.Contain("IgnorePkg = git curl"));
        Assert.That(content, Does.Not.Contain("vim"));
    }

    [Test]
    public void RemoveIgnorePkg_IsNoOp_WhenPackageNotPresent()
    {
        WriteConfig("[options]\nIgnorePkg = git\n");
        var original = ReadConfig();
        var conf = new PacmanConf { IgnorePkg = ["git"] };

        PacmanConfWriter.RemoveIgnorePkg(conf, "vim", _tempPath);

        Assert.That(ReadConfig(), Is.EqualTo(original));
    }

    [Test]
    public void RemoveIgnorePkg_ThrowsOnNullOrWhiteSpace()
    {
        var conf = EmptyConf();

        Assert.That(() => PacmanConfWriter.RemoveIgnorePkg(conf, " ", _tempPath),
            Throws.ArgumentException);
    }

    [Test]
    public void RewriteIgnorePkg_ThrowsFileNotFoundException_WhenFileIsMissing()
    {
        var conf = new PacmanConf { IgnorePkg = ["git"] };
        var missing = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".conf");

        Assert.That(() => PacmanConfWriter.AddIgnorePkg(conf, "vim", missing),
            Throws.TypeOf<FileNotFoundException>());
    }

    [Test]
    public void WriteConfigToFile_PreservesOtherSections()
    {
        WriteConfig("[options]\nColor\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n");
        var conf = EmptyConf();

        PacmanConfWriter.AddIgnorePkg(conf, "vim", _tempPath);

        var content = ReadConfig();
        Assert.That(content, Does.Contain("[core]"));
        Assert.That(content, Does.Contain("Include = /etc/pacman.d/mirrorlist"));
    }

    [Test]
    public void WriteConfigToFile_MergesIgnorePkgLines()
    {
        WriteConfig("[options]\nIgnorePkg = git\n#IgnoreGroup =\nIgnorePkg = vim\n");
        var conf = new PacmanConf { IgnorePkg = ["git", "vim"] };

        PacmanConfWriter.AddIgnorePkg(conf, "nano", _tempPath);

        var content = ReadConfig();
        Assert.Multiple(() =>
        {
            Assert.That(new Regex("IgnorePkg =").Matches(content), Has.Count.EqualTo(1));
            Assert.That(content, Does.Contain("IgnorePkg = git vim nano"));
        });
        Assert.That(content, Does.Contain("#IgnoreGroup"));
    }
}