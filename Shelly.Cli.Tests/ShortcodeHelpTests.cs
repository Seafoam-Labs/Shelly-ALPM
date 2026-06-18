using Shelly.Cli.Shortcodes;

namespace Shelly.Cli.Tests;

[TestFixture]
public class ShortcodeHelpTests
{
    [Test]
    public void ContainsGrammar()
    {
        var section = ShortcodeHelp.BuildHelpSection();

        Assert.That(section, Does.Contain("-<Type><Action>"));
    }

    [Test]
    public void ContainsWorkedExample()
    {
        var section = ShortcodeHelp.BuildHelpSection();

        Assert.That(section, Does.Contain("-SIu firefox"));
        Assert.That(section, Does.Contain("install -u firefox"));
    }

    [Test]
    public void ListsEveryTypeLetter()
    {
        var section = ShortcodeHelp.BuildHelpSection();

        foreach (var letter in new[] { 'I', 'A', 'C', 'F', 'K', 'S', 'U' })
            Assert.That(section, Does.Contain(letter.ToString()),
                $"Help section is missing type letter '{letter}'");
    }
}
