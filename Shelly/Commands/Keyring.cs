using ConsoleAppFramework;
using Shelly.Commands.KeyringCommands;
// ReSharper disable InvalidXmlDocComment
namespace Shelly.Commands;
[RegisterCommands("keyring")]
internal class Keyring
{
    /// <summary>
    /// Initialize the pacman keyring
    /// </summary>
    /// <returns></returns>
    public int Init(ConsoleAppContext context)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? KeyringInitCommands.InitUiMode()
            : KeyringInitCommands.InitConsoleMode();
    }

    /// <summary>
    /// List keys in the keyring
    /// </summary>
    /// <returns></returns>
    public int List(ConsoleAppContext context)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? KeyringListCommands.ListUiMode()
            : KeyringListCommands.ListConsoleMode();
    }

    /// <summary>
    /// Locally sign one or more keys
    /// </summary>
    /// <param name="keys">GPG key IDs or fingerprints to sign</param>
    /// <returns></returns>
    public int Lsign(ConsoleAppContext context, [Argument] string[] keys)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? KeyringLsignCommands.LsignUiMode(keys)
            : KeyringLsignCommands.LsignConsoleMode(keys);
    }

    /// <summary>
    /// Populate the keyring with default or specified keys
    /// </summary>
    /// <param name="keys">optional key names to populate</param>
    /// <returns></returns>
    public int Populate(ConsoleAppContext context, [Argument] string[]? keys = null)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        var keysArray = keys ?? [];
        return globals.UiMode
            ? KeyringPopulateCommands.PopulateUiMode(keysArray)
            : KeyringPopulateCommands.PopulateConsoleMode(keysArray);
    }

    /// <summary>
    /// Receive keys from a keyserver
    /// </summary>
    /// <param name="keys">GPG key IDs or fingerprints to receive</param>
    /// <param name="keyserver">-k,URL of the keyserver to fetch keys from</param>
    /// <returns></returns>
    public int Recv(ConsoleAppContext context, [Argument] string[] keys, string? keyserver = null)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? KeyringRecvCommands.RecvUiMode(keys, keyserver)
            : KeyringRecvCommands.RecvConsoleMode(keys, keyserver);
    }

    /// <summary>
    /// Refresh keys from a keyserver
    /// </summary>
    /// <returns></returns>
    public int Refresh(ConsoleAppContext context)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? KeyringRefreshCommands.RefreshUiMode()
            : KeyringRefreshCommands.RefreshConsoleMode();
    }
}
