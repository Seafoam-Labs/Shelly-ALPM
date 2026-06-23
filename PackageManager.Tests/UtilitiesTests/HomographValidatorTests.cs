using System.Linq;
using PackageManager.Utilities;
using PackageManager.Utilities.PkgBuild;

namespace PackageManager.Tests.UtilitiesTests;

public class HomographValidatorTests
{
    private static ValidationResult ValidateName(string pkgName)
    {
        var info = new PkgbuildInfo { PkgName = pkgName };
        return new HomographValidator().Validate(info);
    }

    [TestCase("firefox")]
    [TestCase("yay-bin")]
    [TestCase("python-requests")]
    [TestCase("gtk4")]
    [TestCase("lib32-mesa")]
    public void Validate_AsciiNames_NoFindings(string name)
    {
        Assert.That(ValidateName(name).HasFindings, Is.False);
    }

    [Test]
    public void Validate_EmptyName_NoFindings()
    {
        Assert.That(ValidateName("").HasFindings, Is.False);
        Assert.That(new HomographValidator().Validate(new PkgbuildInfo()).HasFindings, Is.False);
    }

    [Test]
    public void Validate_CyrillicSpoof_IsCritical()
    {
        // 'а' is Cyrillic U+0430, the rest are Latin -> mixed script.
        var result = ValidateName("\u0430pache");

        Assert.That(result.HasFindings, Is.True);
        Assert.That(result.Findings.Any(f => f.Severity == ValidationSeverity.Critical), Is.True);
        Assert.That(result.Findings[0].Tool, Is.EqualTo("<homograph>"));
    }

    [Test]
    public void Validate_GreekSpoof_IsCritical()
    {
        // Greek 'ο' U+03BF in an otherwise Latin word.
        var result = ValidateName("fire\u03BFx");

        Assert.That(result.Findings.Any(f => f.Severity == ValidationSeverity.Critical), Is.True);
    }

    [Test]
    public void Validate_FullwidthName_IsCritical()
    {
        var result = ValidateName("\uFF46\uFF49\uFF52\uFF45\uFF46\uFF4F\uFF58"); // ｆｉｒｅｆｏｘ

        Assert.That(result.Findings.Any(f => f.Severity == ValidationSeverity.Critical), Is.True);
    }

    [Test]
    public void Validate_ZeroWidthInjected_IsCritical()
    {
        var result = ValidateName("fire\u200Bfox");

        Assert.That(result.Findings.Any(f => f.Severity == ValidationSeverity.Critical), Is.True);
    }

    [Test]
    public void Validate_BidiOverride_IsCritical()
    {
        var result = ValidateName("fox\u202Eelif");

        Assert.That(result.Findings.Any(f => f.Severity == ValidationSeverity.Critical), Is.True);
    }

    [Test]
    public void Validate_AllCyrillicSkeleton_IsCritical()
    {
        // 'аро' all Cyrillic, maps to ASCII look-alike skeleton 'apo'.
        var result = ValidateName("\u0430\u0440\u043E");

        Assert.That(result.Findings.Any(f => f.Severity == ValidationSeverity.Critical), Is.True);
    }

    [Test]
    public void Validate_ConfusableUrl_IsCritical()
    {
        // gіthub.com with Cyrillic 'і' U+0456.
        var info = new PkgbuildInfo
        {
            PkgName = "foo",
            Source = { "https://g\u0456thub.com/foo/bar.git" }
        };

        var result = new HomographValidator().Validate(info);

        Assert.That(result.Findings.Any(f => f.Hook == "source" && f.Severity == ValidationSeverity.Critical), Is.True);
    }

    [Test]
    public void Validate_SuspiciousDependency_IsFlagged()
    {
        var info = new PkgbuildInfo
        {
            PkgName = "foo",
            Depends = { "\u0430pache" }
        };

        var result = new HomographValidator().Validate(info);

        Assert.That(result.Findings.Any(f => f.Hook == "depends"), Is.True);
    }

    [Test]
    public void ValidateField_AsciiMaintainer_NoFindings()
    {
        Assert.That(new HomographValidator().ValidateField("trusted-maintainer", "maintainer").HasFindings, Is.False);
    }

    [Test]
    public void ValidateField_SpoofedMaintainer_IsCritical()
    {
        var result = new HomographValidator().ValidateField("\u0430dmin", "maintainer");

        Assert.That(result.Findings.Any(f => f.Severity == ValidationSeverity.Critical), Is.True);
    }
}
