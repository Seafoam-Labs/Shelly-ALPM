using PackageManager.Utilities;
using Shelly.Utilities;

namespace PackageManager.Tests.UtilitiesTests;

[TestFixture]
[NonParallelizable]
public class XdgPathsTests
{
    private string? _origCache;
    private string? _origData;
    private string? _origConfig;
    private string? _origSudoUser;
    private string? _origHome;

    [SetUp]
    public void SaveEnv()
    {
        _origCache = Environment.GetEnvironmentVariable("XDG_CACHE_HOME");
        _origData = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
        _origConfig = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        _origSudoUser = Environment.GetEnvironmentVariable("SUDO_USER");
        _origHome = Environment.GetEnvironmentVariable("HOME");
        Environment.SetEnvironmentVariable("SUDO_USER", null);
    }

    [TearDown]
    public void RestoreEnv()
    {
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", _origCache);
        Environment.SetEnvironmentVariable("XDG_DATA_HOME", _origData);
        Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", _origConfig);
        Environment.SetEnvironmentVariable("SUDO_USER", _origSudoUser);
        Environment.SetEnvironmentVariable("HOME", _origHome);
    }

    [Test]
    public void CacheHome_Unset_FallsBackToHomeDotCache()
    {
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", null);
        Environment.SetEnvironmentVariable("HOME", "/tmp/fakehome");

        Assert.That(XdgPaths.CacheHome(), Is.EqualTo("/tmp/fakehome/.cache"));
    }

    [Test]
    public void CacheHome_Empty_FallsBackToDefault()
    {
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", "");
        Environment.SetEnvironmentVariable("HOME", "/tmp/fakehome");

        Assert.That(XdgPaths.CacheHome(), Is.EqualTo("/tmp/fakehome/.cache"));
    }

    [Test]
    public void CacheHome_RelativePath_IsIgnored()
    {
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", "relative/path");
        Environment.SetEnvironmentVariable("HOME", "/tmp/fakehome");

        Assert.That(XdgPaths.CacheHome(), Is.EqualTo("/tmp/fakehome/.cache"));
    }

    [Test]
    public void CacheHome_AbsolutePath_IsHonored()
    {
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", "/tmp/xcache");

        Assert.That(XdgPaths.CacheHome(), Is.EqualTo("/tmp/xcache"));
    }
    

    [Test]
    public void ShellyCache_WithParts_ComposesCorrectly()
    {
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", "/tmp/xcache");

        Assert.That(XdgPaths.ShellyCache("pkg", "sub"),
            Is.EqualTo("/tmp/xcache/Shelly/pkg/sub"));
    }

    [Test]
    public void ShellyData_ComposesCorrectly()
    {
        Environment.SetEnvironmentVariable("XDG_DATA_HOME", "/tmp/xdata");

        Assert.That(XdgPaths.ShellyData("vcs.json"),
            Is.EqualTo("/tmp/xdata/Shelly/vcs.json"));
    }

    [Test]
    public void ShellyConfig_UsesLowercaseShelly()
    {
        Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", "/tmp/xconfig");

        Assert.That(XdgPaths.ShellyConfig("settings.toml"),
            Is.EqualTo("/tmp/xconfig/shelly/settings.toml"));
    }

    [Test]
    public void InvokingUserHome_WithoutSudoUser_FallsBackToHome()
    {
        Environment.SetEnvironmentVariable("SUDO_USER", null);
        Environment.SetEnvironmentVariable("HOME", "/tmp/fakehome");

        Assert.That(XdgPaths.InvokingUserHome(), Is.EqualTo("/tmp/fakehome"));
    }
    

    [Test]
    public void Defaults_UnsetEnv_ProduceLegacyPaths()
    {
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", null);
        Environment.SetEnvironmentVariable("XDG_DATA_HOME", null);
        Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", null);
        Environment.SetEnvironmentVariable("HOME", "/tmp/fakehome");

        Assert.Multiple(() =>
        {
            Assert.That(XdgPaths.ShellyCache("x"), Is.EqualTo("/tmp/fakehome/.cache/Shelly/x"));
            Assert.That(XdgPaths.ShellyData("vcs.json"), Is.EqualTo("/tmp/fakehome/.local/share/Shelly/vcs.json"));
            Assert.That(XdgPaths.ShellyConfig("config.json"), Is.EqualTo("/tmp/fakehome/.config/shelly/config.json"));
        });
    }

    [Test]
    public void Casing_IsIntentional()
    {
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", "/tmp/c");
        Environment.SetEnvironmentVariable("XDG_DATA_HOME", "/tmp/d");
        Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", "/tmp/cfg");

        Assert.Multiple(() =>
        {
            Assert.That(XdgPaths.ShellyCache("a"), Does.Contain("/Shelly/").And.Not.Contain("/shelly/"));
            Assert.That(XdgPaths.ShellyData("a"), Does.Contain("/Shelly/").And.Not.Contain("/shelly/"));
            Assert.That(XdgPaths.ShellyConfig("a"), Does.Contain("/shelly/").And.Not.Contain("/Shelly/"));
        });
    }

    [Test]
    public void ShellyCache_NoParts_ReturnsRoot()
    {
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", "/tmp/xcache");

        Assert.That(XdgPaths.ShellyCache(), Is.EqualTo("/tmp/xcache/Shelly"));
    }

    [Test]
    public void BackToBack_NoStateLeak()
    {
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", "/tmp/a");
        var first = XdgPaths.CacheHome();
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", "/tmp/b");
        var second = XdgPaths.CacheHome();

        Assert.Multiple(() =>
        {
            Assert.That(first, Is.EqualTo("/tmp/a"));
            Assert.That(second, Is.EqualTo("/tmp/b"));
        });
    }

    [Test]
    public void CacheHome_WhitespaceOnly_FallsBackToDefault()
    {
        Environment.SetEnvironmentVariable("XDG_CACHE_HOME", "   ");
        Environment.SetEnvironmentVariable("HOME", "/tmp/fakehome");

        Assert.That(XdgPaths.CacheHome(), Is.EqualTo("/tmp/fakehome/.cache"));
    }

    [Test]
    public void DataHome_Defaults_To_LocalShare()
    {
        Environment.SetEnvironmentVariable("XDG_DATA_HOME", null);
        Environment.SetEnvironmentVariable("HOME", "/tmp/fakehome");

        Assert.That(XdgPaths.DataHome(), Is.EqualTo("/tmp/fakehome/.local/share"));
    }

    [Test]
    public void ConfigHome_Defaults_To_DotConfig()
    {
        Environment.SetEnvironmentVariable("XDG_CONFIG_HOME", null);
        Environment.SetEnvironmentVariable("HOME", "/tmp/fakehome");

        Assert.That(XdgPaths.ConfigHome(), Is.EqualTo("/tmp/fakehome/.config"));
    }

    [Test]
    public void StateHome_Defaults_To_LocalState()
    {
        Environment.SetEnvironmentVariable("XDG_STATE_HOME", null);
        Environment.SetEnvironmentVariable("HOME", "/tmp/fakehome");

        Assert.That(XdgPaths.StateHome(), Is.EqualTo("/tmp/fakehome/.local/state"));
    }
}
