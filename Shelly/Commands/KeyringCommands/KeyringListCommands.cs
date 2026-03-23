namespace Shelly.Commands.KeyringCommands;

internal static class KeyringListCommands
{
    internal static int ListUiMode()
    {
        Console.Error.WriteLine("Listing keys in keyring...");
        return PacmanKeyRunner.Run("--list-keys", true);
    }

    internal static int ListConsoleMode()
    {
        RootElevator.EnsureRootExectuion();
        Console.WriteLine("Listing keys in keyring...");
        return PacmanKeyRunner.Run("--list-keys");
    }
}
