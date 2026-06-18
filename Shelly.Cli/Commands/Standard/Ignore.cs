using System.CommandLine;
using System.Text.Json;
using PackageManager.Alpm;
using static System.CommandLine.ArgumentArity;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Standard;

public class Ignore : GlobalSettingsCommand
{
    private bool List { get; set; }

    private bool Add { get; set; }

    private bool Remove { get; set; }

    private bool Clear { get; set; }

    private string[] Packages { get; set; } = [];

    public static Command Create()
    {
        var list = new Option<bool>("--list", "-l") { Description = "List ignored packages" };
        var add = new Option<bool>("--add", "-a") { Description = "Add a package to the ignore list" };
        var remove = new Option<bool>("--remove", "-r") { Description = "Remove a package from the ignore list" };
        var clear = new Option<bool>("--clear", "-c") { Description = "Clear the ignore list" };
        var packages = new Argument<string[]>("packages") { Description = "The packages to interact with", Arity = ZeroOrMore };

        var command = new Command("ignore", "Manage ignored packages") { list, add, remove, clear, packages };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Ignore
            {
                List = parseResult.GetValue(list),
                Add = parseResult.GetValue(add),
                Remove = parseResult.GetValue(remove),
                Clear = parseResult.GetValue(clear),
                Packages = parseResult.GetValue(packages) ?? []
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

        if (Packages.Length == 0 && !List && !Clear)
        {
            console.WriteLine(Colorize("No packages specified", ConsoleColor.Red));
            return;
        }

        RootElevator.EnsureRootExectuion();
        using var manager = new AlpmManager();
        if (Add)
        {
            manager.IgnorePackages(Packages);
            var formatPackages = string.Join(", ", Packages);
            console.WriteLine(Colorize($"Added to IgnorePkg list: {formatPackages}", ConsoleColor.Green));
            return;
        }

        if (Remove)
        {
            manager.UnignorePackages(Packages);
            var formatPackages = string.Join(", ", Packages);
            console.WriteLine(Colorize($"Removed from IgnorePkg list: {formatPackages}", ConsoleColor.Green));
            return;
        }

        var ignored = manager.GetIgnoredPackages();
        if (Clear)
        {
            manager.UnignorePackages(ignored);
            console.WriteLine(Colorize("Cleared ignored packages.", ConsoleColor.Green));
            return;
        }


        if (List)
        {
            string message;
            if (JsonOutput)
            {
                message = JsonSerializer.Serialize(ignored, ShellyCliJsonContext.Default.ListString);
            }
            else if (ignored.Count == 0)
            {
                message = Colorize("IgnorePkg list is empty.", ConsoleColor.Yellow);
            }
            else
            {
                var formatPackages = string.Join(", ", ignored);
                message = Colorize($"Total: {ignored.Count} ignored packages: {formatPackages}", ConsoleColor.Green);
            }

            console.WriteLine(message);
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Packages.Length == 0 && !List && !Clear) UiFrames.Error("No packages specified");

        using var manager = new AlpmManager();
        if (Add)
        {
            manager.IgnorePackages(Packages);
            var formatPackages = string.Join(", ", Packages);
            UiFrames.Info($"Added to IgnorePkg list: {formatPackages}");
            return;
        }

        if (Remove)
        {
            manager.UnignorePackages(Packages);
            var formatPackages = string.Join(", ", Packages);
            UiFrames.Info($"Removed from IgnorePkg list: {formatPackages}");
            return;
        }

        var ignored = manager.GetIgnoredPackages();
        if (Clear)
        {
            manager.UnignorePackages(ignored);
            UiFrames.Info("Cleared ignored packages.");
            return;
        }

        if (List)
        {
            UiFrames.Frame(ignored);
            UiFrames.Info(ignored.Count == 0
                ? "IgnorePkg list is empty."
                : $"Total: {ignored.Count} ignored packages");
        }
    }
}