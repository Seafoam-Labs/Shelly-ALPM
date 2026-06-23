using System.Reflection;
using Shelly.Cli.Commands.Standard;

namespace Shelly.Cli.Tests;

[TestFixture]
public class InstallClassifyTests
{
    private static readonly MethodInfo ClassifyMethod =
        typeof(Install).GetMethod("Classify", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("Classify method not found on Install.");

    private static readonly MethodInfo IsRepoQualifiedNameMethod =
        typeof(Install).GetMethod("IsRepoQualifiedName", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("IsRepoQualifiedName method not found on Install.");

    private static readonly MethodInfo IsFilePathMethod =
        typeof(Install).GetMethod("IsFilePath", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("IsFilePath method not found on Install.");

    private static readonly MethodInfo IsUrlMethod =
        typeof(Install).GetMethod("IsUrl", BindingFlags.NonPublic | BindingFlags.Static)
        ?? throw new InvalidOperationException("IsUrl method not found on Install.");

    private static string Classify(string value)
    {
        var result = ClassifyMethod.Invoke(null, [value]);
        return result?.ToString() ?? throw new InvalidOperationException("Classify returned null.");
    }

    private static bool IsRepoQualifiedName(string value)
        => (bool)IsRepoQualifiedNameMethod.Invoke(null, [value])!;

    private static bool IsFilePath(string value)
        => (bool)IsFilePathMethod.Invoke(null, [value])!;

    private static bool IsUrl(string value)
        => (bool)IsUrlMethod.Invoke(null, [value])!;

    // --- Classify: bare package names ---

    [TestCase("firefox")]
    [TestCase("glibc")]
    [TestCase("base-devel")]
    [TestCase("python-pip")]
    [TestCase("gtk+")]
    public void Classify_BarePackageName_ReturnsPackageName(string value)
    {
        Assert.That(Classify(value), Is.EqualTo("PackageName"));
    }

    // --- Classify: repo-qualified names ---

    [TestCase("extra/firefox")]
    [TestCase("core/glibc")]
    [TestCase("community/base-devel")]
    [TestCase("multilib/lib32-glibc")]
    public void Classify_RepoQualifiedName_ReturnsPackageName(string value)
    {
        Assert.That(Classify(value), Is.EqualTo("PackageName"));
    }

    // --- Classify: file paths ---

    [TestCase("./firefox-1.0.pkg.tar.zst")]
    [TestCase("/home/user/firefox-1.0.pkg.tar.zst")]
    [TestCase("dir/foo.pkg.tar.zst")]
    [TestCase("~/firefox.pkg.tar.zst")]
    [TestCase("firefox.pkg.tar.zst")]
    public void Classify_FilePath_ReturnsFilePath(string value)
    {
        Assert.That(Classify(value), Is.EqualTo("FilePath"));
    }

    // --- Classify: URLs ---

    [TestCase("http://example.com/firefox.pkg.tar.zst")]
    [TestCase("https://example.com/firefox.pkg.tar.zst")]
    [TestCase("ftp://example.com/firefox.pkg.tar.zst")]
    public void Classify_Url_ReturnsUrl(string value)
    {
        Assert.That(Classify(value), Is.EqualTo("Url"));
    }

    // --- IsRepoQualifiedName ---

    [TestCase("extra/firefox", ExpectedResult = true)]
    [TestCase("core/glibc", ExpectedResult = true)]
    [TestCase("firefox", ExpectedResult = false)]
    [TestCase("a/b/c", ExpectedResult = false)]
    [TestCase("extra/", ExpectedResult = false)]
    [TestCase("/firefox", ExpectedResult = false)]
    [TestCase("~/extra/firefox", ExpectedResult = false)]
    [TestCase("dir/foo.pkg.tar.zst", ExpectedResult = false)]
    [TestCase("", ExpectedResult = false)]
    [TestCase("   ", ExpectedResult = false)]
    public bool IsRepoQualifiedName_Cases(string value)
    {
        return IsRepoQualifiedName(value);
    }

    // --- IsFilePath ---

    [TestCase("/home/user/file", ExpectedResult = true)]
    [TestCase("dir/file", ExpectedResult = true)]
    [TestCase("~/file", ExpectedResult = true)]
    [TestCase("firefox.pkg.tar.zst", ExpectedResult = true)]
    [TestCase("firefox", ExpectedResult = false)]
    [TestCase("https://example.com/x", ExpectedResult = false)]
    [TestCase("", ExpectedResult = false)]
    public bool IsFilePath_Cases(string value)
    {
        return IsFilePath(value);
    }

    // --- IsUrl ---

    [TestCase("http://example.com", ExpectedResult = true)]
    [TestCase("https://example.com/x", ExpectedResult = true)]
    [TestCase("ftp://example.com/x", ExpectedResult = true)]
    [TestCase("firefox", ExpectedResult = false)]
    [TestCase("extra/firefox", ExpectedResult = false)]
    [TestCase("/home/user/file", ExpectedResult = false)]
    [TestCase("file:///home/user/file", ExpectedResult = false)]
    public bool IsUrl_Cases(string value)
    {
        return IsUrl(value);
    }
}
