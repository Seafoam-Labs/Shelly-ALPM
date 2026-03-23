namespace Shelly.Commands.KeyringCommands;

internal static class KeyringPopulateCommands
{
    internal static int PopulateUiMode(string[] keys)
    {
        var args = "--populate";
        if (keys.Length > 0)
        {
            args += " " + string.Join(" ", keys);
            Console.Error.WriteLine($"Populating keyring with: {string.Join(", ", keys)}...");
        }
        else
        {
            Console.Error.WriteLine("Populating keyring with default keys...");
        }

        var result = PacmanKeyRunner.Run(args, true);
        if (result == 0)
        {
            Console.Error.WriteLine("Keyring populated successfully!");
        }
        else
        {
            Console.Error.WriteLine("Failed to populate keyring.");
        }

        return result;
    }

    internal static int PopulateConsoleMode(string[] keys)
    {
        RootElevator.EnsureRootExectuion();
        var args = "--populate";
        if (keys.Length > 0)
        {
            args += " " + string.Join(" ", keys);
            Console.WriteLine($"Populating keyring with: {string.Join(", ", keys)}...");
        }
        else
        {
            Console.WriteLine("Populating keyring with default keys...");
        }

        var result = PacmanKeyRunner.Run(args);
        if (result == 0)
        {
            Console.WriteLine("Keyring populated successfully!");
        }
        else
        {
            Console.WriteLine("Failed to populate keyring.");
        }

        return result;
    }
}
