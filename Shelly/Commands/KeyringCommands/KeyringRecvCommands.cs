namespace Shelly.Commands.KeyringCommands;

internal static class KeyringRecvCommands
{
    internal static int RecvUiMode(string[] keys, string? keyserver)
    {
        if (keys.Length == 0)
        {
            Console.Error.WriteLine("Error: No key IDs specified");
            return 1;
        }

        var args = "--recv-keys " + string.Join(" ", keys);
        if (!string.IsNullOrEmpty(keyserver))
        {
            args += $" --keyserver {keyserver}";
        }

        Console.Error.WriteLine($"Receiving keys: {string.Join(", ", keys)}...");
        var result = PacmanKeyRunner.Run(args, true);
        if (result == 0)
        {
            Console.Error.WriteLine("Keys received successfully!");
        }
        else
        {
            Console.Error.WriteLine("Failed to receive keys.");
        }

        return result;
    }

    internal static int RecvConsoleMode(string[] keys, string? keyserver)
    {
        if (keys.Length == 0)
        {
            Console.WriteLine("Error: No key IDs specified");
            return 1;
        }

        RootElevator.EnsureRootExectuion();
        var args = "--recv-keys " + string.Join(" ", keys);
        if (!string.IsNullOrEmpty(keyserver))
        {
            args += $" --keyserver {keyserver}";
        }

        Console.WriteLine($"Receiving keys: {string.Join(", ", keys)}...");
        var result = PacmanKeyRunner.Run(args);
        if (result == 0)
        {
            Console.WriteLine("Keys received successfully!");
        }
        else
        {
            Console.WriteLine("Failed to receive keys.");
        }

        return result;
    }
}
