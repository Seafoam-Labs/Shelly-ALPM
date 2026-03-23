namespace Shelly.Commands.KeyringCommands;

internal static class KeyringRefreshCommands
{
    internal static int RefreshUiMode()
    {
        Console.Error.WriteLine("Refreshing keys from keyserver...");
        var result = PacmanKeyRunner.Run("--refresh-keys", true);
        if (result == 0)
        {
            Console.Error.WriteLine("Keys refreshed successfully!");
        }
        else
        {
            Console.Error.WriteLine("Failed to refresh keys.");
        }

        return result;
    }

    internal static int RefreshConsoleMode()
    {
        RootElevator.EnsureRootExectuion();
        Console.WriteLine("Refreshing keys from keyserver...");
        var result = PacmanKeyRunner.Run("--refresh-keys");
        if (result == 0)
        {
            Console.WriteLine("Keys refreshed successfully!");
        }
        else
        {
            Console.WriteLine("Failed to refresh keys.");
        }

        return result;
    }
}
