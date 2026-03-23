namespace Shelly.Commands.KeyringCommands;

internal static class KeyringLsignCommands
{
    internal static int LsignUiMode(string[] keys)
    {
        if (keys.Length == 0)
        {
            Console.Error.WriteLine("Error: No key IDs specified");
            return 1;
        }

        Console.Error.WriteLine($"Locally signing keys: {string.Join(", ", keys)}...");

        foreach (var key in keys)
        {
            var result = PacmanKeyRunner.Run($"--lsign-key {key}", true);
            if (result != 0)
            {
                Console.Error.WriteLine($"Failed to sign key: {key}");
                return result;
            }
        }

        Console.Error.WriteLine("Keys signed successfully!");
        return 0;
    }

    internal static int LsignConsoleMode(string[] keys)
    {
        if (keys.Length == 0)
        {
            Console.WriteLine("Error: No key IDs specified");
            return 1;
        }

        RootElevator.EnsureRootExectuion();
        Console.WriteLine($"Locally signing keys: {string.Join(", ", keys)}...");

        foreach (var key in keys)
        {
            var result = PacmanKeyRunner.Run($"--lsign-key {key}");
            if (result != 0)
            {
                Console.WriteLine($"Failed to sign key: {key}");
                return result;
            }
        }

        Console.WriteLine("Keys signed successfully!");
        return 0;
    }
}
