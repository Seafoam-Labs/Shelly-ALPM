using System.CommandLine;
using Shelly.Utilities.Eventing;
using static System.CommandLine.ArgumentArity;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Keyring;

public class Keyring : GlobalSettingsCommand
{
    private string Action { get; set; } = string.Empty;

    private string[] Keys { get; set; } = [];

    private string? Keyserver { get; set; }

    public static Command Create()
    {
        var action = new Argument<string>("action") { Description = "The keyring action to perform" };
        action.AcceptOnlyFromAmong("init", "list", "refresh", "lsign", "populate", "recv");

        var keys = new Argument<string[]>("keys") { Description = "The key IDs to operate on", Arity = ZeroOrMore };
        var keyserver = new Option<string>("--keyserver") { Description = "The keyserver to use" };

        var command = new Command("keyring", "Manage the pacman keyring") { action, keys, keyserver };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Keyring
            {
                Action = parseResult.GetValue(action) ?? string.Empty,
                Keys = parseResult.GetValue(keys) ?? [],
                Keyserver = parseResult.GetValue(keyserver)
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        RootElevator.EnsureRootExectuion();

        switch (Action)
        {
            case "init":
                console.WriteLine(Colorize("Initializing pacman keyring...", ConsoleColor.Yellow));
                var initResult = PacmanKeyRunner.Run(console, "--init");
                console.WriteLine(initResult == 0
                    ? Colorize("Keyring initialized successfully!", ConsoleColor.Green)
                    : Colorize("Failed to initialize keyring.", ConsoleColor.Red));
                break;

            case "list":
                console.WriteLine(Colorize("Listing keys in keyring...", ConsoleColor.Yellow));
                PacmanKeyRunner.Run(console, "--list-keys");
                break;

            case "refresh":
                console.WriteLine(Colorize("Refreshing keys from keyserver...", ConsoleColor.Yellow));
                var refreshResult = PacmanKeyRunner.Run(console, "--refresh-keys");
                console.WriteLine(refreshResult == 0
                    ? Colorize("Keys refreshed successfully!", ConsoleColor.Green)
                    : Colorize("Failed to refresh keys.", ConsoleColor.Red));
                break;

            case "lsign":
                if (Keys.Length == 0)
                {
                    console.WriteLine(Colorize("Error: No key IDs specified", ConsoleColor.Red));
                    return;
                }

                console.WriteLine(Colorize($"Locally signing keys: {string.Join(", ", Keys)}...", ConsoleColor.Yellow));
                foreach (var key in Keys)
                {
                    var result = PacmanKeyRunner.Run(console, $"--lsign-key {key}");
                    if (result != 0)
                    {
                        console.WriteLine(Colorize($"Failed to sign key: {key}", ConsoleColor.Red));
                        return;
                    }
                }

                console.WriteLine(Colorize("Keys signed successfully!", ConsoleColor.Green));
                break;

            case "populate":
                var populateArgs = "--populate";
                if (Keys.Length > 0)
                {
                    populateArgs += " " + string.Join(" ", Keys);
                    console.WriteLine(Colorize($"Populating keyring with: {string.Join(", ", Keys)}...", ConsoleColor.Yellow));
                }
                else
                {
                    console.WriteLine(Colorize("Populating keyring with default keys...", ConsoleColor.Yellow));
                }

                var populateResult = PacmanKeyRunner.Run(console, populateArgs);
                console.WriteLine(populateResult == 0
                    ? Colorize("Keyring populated successfully!", ConsoleColor.Green)
                    : Colorize("Failed to populate keyring.", ConsoleColor.Red));
                break;

            case "recv":
                if (Keys.Length == 0)
                {
                    console.WriteLine(Colorize("Error: No key IDs specified", ConsoleColor.Red));
                    return;
                }

                var recvArgs = "--recv-keys " + string.Join(" ", Keys);
                if (!string.IsNullOrEmpty(Keyserver))
                {
                    recvArgs += $" --keyserver {Keyserver}";
                }

                console.WriteLine(Colorize($"Receiving keys: {string.Join(", ", Keys)}...", ConsoleColor.Yellow));
                var recvResult = PacmanKeyRunner.Run(console, recvArgs);
                console.WriteLine(recvResult == 0
                    ? Colorize("Keys received successfully!", ConsoleColor.Green)
                    : Colorize("Failed to receive keys.", ConsoleColor.Red));
                break;

            default:
                console.WriteLine(Colorize($"Unknown action: {Action}", ConsoleColor.Red));
                break;
        }
    }

    public override ValueTask ExecuteUiMode()
    {
        var console = new SystemShellyConsole();

        switch (Action)
        {
            case "init":
                UiFrames.Info("Initializing pacman keyring...", AlpmEvents.TransactionStart);
                var initResult = PacmanKeyRunner.Run(console, "--init");
                UiFrames.TxFinish(initResult == 0, "Keyring initialized successfully!", "Failed to initialize keyring.");
                break;

            case "list":
                UiFrames.Info("Listing keys in keyring...", AlpmEvents.TransactionStart);
                var listResult = PacmanKeyRunner.Run(console, "--list-keys");
                UiFrames.TxFinish(listResult == 0, "Keys listed.", "Failed to list keys.");
                break;

            case "refresh":
                UiFrames.Info("Refreshing keys from keyserver...", AlpmEvents.TransactionStart);
                var refreshResult = PacmanKeyRunner.Run(console, "--refresh-keys");
                UiFrames.TxFinish(refreshResult == 0, "Keys refreshed successfully!", "Failed to refresh keys.");
                break;

            case "lsign":
                if (Keys.Length == 0)
                {
                    UiFrames.Error("No key IDs specified");
                    return ValueTask.CompletedTask;
                }

                UiFrames.Info($"Locally signing keys: {string.Join(", ", Keys)}...", AlpmEvents.TransactionStart);
                foreach (var key in Keys)
                {
                    var result = PacmanKeyRunner.Run(console, $"--lsign-key {key}");
                    if (result != 0)
                    {
                        UiFrames.Error($"Failed to sign key: {key}");
                        UiFrames.TxFinish(false, "Keys signed successfully!", "Failed to sign keys.");
                        return ValueTask.CompletedTask;
                    }
                }

                UiFrames.TxFinish(true, "Keys signed successfully!", "Failed to sign keys.");
                break;

            case "populate":
                var populateArgs = "--populate";
                if (Keys.Length > 0)
                {
                    populateArgs += " " + string.Join(" ", Keys);
                    UiFrames.Info($"Populating keyring with: {string.Join(", ", Keys)}...", AlpmEvents.TransactionStart);
                }
                else
                {
                    UiFrames.Info("Populating keyring with default keys...", AlpmEvents.TransactionStart);
                }

                var populateResult = PacmanKeyRunner.Run(console, populateArgs);
                UiFrames.TxFinish(populateResult == 0, "Keyring populated successfully!", "Failed to populate keyring.");
                break;

            case "recv":
                if (Keys.Length == 0)
                {
                    UiFrames.Error("No key IDs specified");
                    return ValueTask.CompletedTask;
                }

                var recvArgs = "--recv-keys " + string.Join(" ", Keys);
                if (!string.IsNullOrEmpty(Keyserver))
                {
                    recvArgs += $" --keyserver {Keyserver}";
                }

                UiFrames.Info($"Receiving keys: {string.Join(", ", Keys)}...", AlpmEvents.TransactionStart);
                var recvResult = PacmanKeyRunner.Run(console, recvArgs);
                UiFrames.TxFinish(recvResult == 0, "Keys received successfully!", "Failed to receive keys.");
                break;

            default:
                UiFrames.Error($"Unknown action: {Action}");
                break;
        }

        return ValueTask.CompletedTask;
    }
}
