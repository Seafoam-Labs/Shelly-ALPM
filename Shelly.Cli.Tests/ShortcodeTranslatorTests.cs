using Shelly.Cli.Shortcodes;

namespace Shelly.Cli.Tests;

[TestFixture]
public class ShortcodeTranslatorTests
{
    [Test]
    public void Install_WithUpgradeModifier()
    {
        var result = ShortcodeTranslator.Translate(["-SIu", "firefox"]);

        Assert.That(result, Is.EqualTo(new[] { "install", "-u", "firefox" }));
    }

    [Test]
    public void Query_ExpandsModifiers()
    {
        var result = ShortcodeTranslator.Translate(["-SQad", "query"]);

        Assert.That(result, Is.EqualTo(new[] { "query", "-a", "-d", "query" }));
    }

    [Test]
    public void Remove_WithBundledModifiers()
    {
        var result = ShortcodeTranslator.Translate(["-SRcr", "pkg"]);

        Assert.That(result, Is.EqualTo(new[] { "remove", "-c", "-r", "pkg" }));
    }

    [Test]
    public void Aur_Search()
    {
        var result = ShortcodeTranslator.Translate(["-AS", "query"]);

        Assert.That(result, Is.EqualTo(new[] { "aur", "search", "query" }));
    }

    [Test]
    public void Flatpak_Uninstall()
    {
        var result = ShortcodeTranslator.Translate(["-FR", "app"]);

        Assert.That(result, Is.EqualTo(new[] { "flatpak", "uninstall", "app" }));
    }

    [Test]
    public void Keyring_Recv()
    {
        var result = ShortcodeTranslator.Translate(["-KV", "ABCD1234"]);

        Assert.That(result, Is.EqualTo(new[] { "keyring", "recv", "ABCD1234" }));
    }

    [Test]
    public void Utility_CacheClean()
    {
        var result = ShortcodeTranslator.Translate(["-UC"]);

        Assert.That(result, Is.EqualTo(new[] { "cache-clean" }));
    }

    [Test]
    public void PreservesTrailingGlobals()
    {
        var result = ShortcodeTranslator.Translate(["-SIu", "pkg", "-n", "--json"]);

        Assert.That(result, Is.EqualTo(new[] { "install", "-u", "pkg", "-n", "--json" }));
    }

    [Test]
    public void PassesThroughLongFormVerb()
    {
        string[] args = ["install", "pkg"];
        var result = ShortcodeTranslator.Translate(args);

        Assert.That(result, Is.SameAs(args));
    }

    [Test]
    public void PassesThroughGroupedLongForm()
    {
        string[] args = ["aur", "search", "x"];
        var result = ShortcodeTranslator.Translate(args);

        Assert.That(result, Is.SameAs(args));
    }

    [Test]
    public void PassesThroughLongOption()
    {
        string[] args = ["--json", "query", "-a", "x"];
        var result = ShortcodeTranslator.Translate(args);

        Assert.That(result, Is.SameAs(args));
    }

    [Test]
    public void PassesThroughSingleShortGlobal()
    {
        string[] args = ["-n"];
        var result = ShortcodeTranslator.Translate(args);

        Assert.That(result, Is.SameAs(args));
    }

    [Test]
    public void UnknownTypePassesThrough()
    {
        string[] args = ["-ZZ", "x"];
        var result = ShortcodeTranslator.Translate(args);

        Assert.That(result, Is.SameAs(args));
    }

    [Test]
    public void UnknownActionThrows()
    {
        Assert.Throws<ShortcodeException>(() => ShortcodeTranslator.Translate(["-SZ", "x"]));
    }

    [Test]
    public void UnknownModifierThrows()
    {
        Assert.Throws<ShortcodeException>(() => ShortcodeTranslator.Translate(["-SIx", "x"]));
    }

    [Test]
    public void KeyringWithModifiersThrows()
    {
        Assert.Throws<ShortcodeException>(() => ShortcodeTranslator.Translate(["-KVx", "x"]));
    }
}
