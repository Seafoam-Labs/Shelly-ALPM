using System.IO;
using NUnit.Framework;
using PackageManager.Alpm.DistributionHooks;

namespace PackageManager.Tests.UtilitiesTests;

[TestFixture]
internal class OsReleaseTests
{
    [Test]
    public void ParsePrettyName_ReturnsPrettyName_WhenPresent()
    {
        string[] lines =
        [
            "NAME=\"CachyOS Linux\"",
            "PRETTY_NAME=\"CachyOS\"",
            "ID=cachyos"
        ];

        Assert.That(OsRelease.ParsePrettyName(lines), Is.EqualTo("CachyOS"));
    }

    [Test]
    public void ParsePrettyName_FallsBackToName_WhenPrettyNameMissing()
    {
        string[] lines =
        [
            "ID=arch",
            "NAME=\"Arch Linux\""
        ];

        Assert.That(OsRelease.ParsePrettyName(lines), Is.EqualTo("Arch Linux"));
    }

    [Test]
    public void ParsePrettyName_StripsSingleQuotes()
    {
        string[] lines = ["PRETTY_NAME='Debian GNU/Linux'"];

        Assert.That(OsRelease.ParsePrettyName(lines), Is.EqualTo("Debian GNU/Linux"));
    }

    [Test]
    public void ParsePrettyName_HandlesUnquotedValues()
    {
        string[] lines = ["PRETTY_NAME=Gentoo"];

        Assert.That(OsRelease.ParsePrettyName(lines), Is.EqualTo("Gentoo"));
    }

    [Test]
    public void ParsePrettyName_TrimsSurroundingWhitespace()
    {
        string[] lines = ["  PRETTY_NAME =  \"Fedora Linux\"  "];

        Assert.That(OsRelease.ParsePrettyName(lines), Is.EqualTo("Fedora Linux"));
    }

    [Test]
    public void ParsePrettyName_IgnoresCommentsAndBlankAndMalformedLines()
    {
        string[] lines =
        [
            "",
            "# this is a comment",
            "=novalue",
            "BUILD_ID",
            "PRETTY_NAME=\"Ubuntu 24.04 LTS\""
        ];

        Assert.That(OsRelease.ParsePrettyName(lines), Is.EqualTo("Ubuntu 24.04 LTS"));
    }

    [Test]
    public void ParsePrettyName_ReturnsNull_WhenNoNameKeys()
    {
        string[] lines =
        [
            "ID=arch",
            "VERSION_ID=rolling"
        ];

        Assert.That(OsRelease.ParsePrettyName(lines), Is.Null);
    }

    [Test]
    public void ParsePrettyName_PrefersPrettyNameOverName_RegardlessOfOrder()
    {
        string[] lines =
        [
            "PRETTY_NAME=\"CachyOS\"",
            "NAME=\"CachyOS Linux\""
        ];

        Assert.That(OsRelease.ParsePrettyName(lines), Is.EqualTo("CachyOS"));
    }

    [Test]
    public void ParsePrettyName_ReturnsEmptyString_WhenValueEmpty()
    {
        string[] lines = ["PRETTY_NAME=\"\""];

        Assert.That(OsRelease.ParsePrettyName(lines), Is.EqualTo(string.Empty));
    }

    [Test]
    public void GetPrettyName_ReadsFromExistingFile()
    {
        var path = Path.GetTempFileName();
        try
        {
            File.WriteAllText(path, "NAME=\"Test\"\nPRETTY_NAME=\"CachyOS\"\n");

            Assert.That(OsRelease.GetPrettyName(path), Is.EqualTo("CachyOS"));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Test]
    public void GetPrettyName_UsesFirstExistingCandidatePath()
    {
        var missing = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
        var existing = Path.GetTempFileName();
        try
        {
            File.WriteAllText(existing, "PRETTY_NAME=\"FallbackOS\"\n");

            Assert.That(OsRelease.GetPrettyName(missing, existing), Is.EqualTo("FallbackOS"));
        }
        finally
        {
            File.Delete(existing);
        }
    }

    [Test]
    public void GetPrettyName_ReturnsNull_WhenNoCandidateExists()
    {
        var missing = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());

        Assert.That(OsRelease.GetPrettyName(missing), Is.Null);
    }
}
