namespace Shelly.Commands.KeyringCommands;

internal static class KeyringInitCommands
{
    internal static int InitUiMode()
    {
        Console.Error.WriteLine("Initializing pacman keyring...");
        var result = PacmanKeyRunner.Run("--init", true);
        if (result == 0)
        {
            Console.Error.WriteLine("Keyring initialized successfully!");
        }
        else
        {
            Console.Error.WriteLine("Failed to initialize keyring.");
        }

        return result;
    }

    internal static int InitConsoleMode()
    {
        RootElevator.EnsureRootExectuion();
        Console.WriteLine("Initializing pacman keyring...");
        var result = PacmanKeyRunner.Run("--init");
        if (result == 0)
        {
            Console.WriteLine("Keyring initialized successfully!");
        }
        else
        {
            Console.WriteLine("Failed to initialize keyring.");
        }

        return result;
    }
}
