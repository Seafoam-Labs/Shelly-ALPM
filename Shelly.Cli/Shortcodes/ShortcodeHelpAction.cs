using System.CommandLine;
using System.CommandLine.Help;
using System.CommandLine.Invocation;

namespace Shelly.Cli.Shortcodes;

internal sealed class ShortcodeHelpAction : SynchronousCommandLineAction
{
    private readonly HelpAction _inner;

    public ShortcodeHelpAction(HelpAction inner) => _inner = inner;

    public override int Invoke(ParseResult parseResult)
    {
        var result = _inner.Invoke(parseResult);
        parseResult.InvocationConfiguration.Output.WriteLine(ShortcodeHelp.BuildHelpSection());
        return result;
    }
}
