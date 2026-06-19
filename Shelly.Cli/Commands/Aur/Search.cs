using System.CommandLine;
using PackageManager.Aur;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Commands.Aur;

public class Search : GlobalSettingsCommand
{
    private string[] Query { get; set; } = Array.Empty<string>();

    public static Command Create()
    {
        var query = new Argument<string[]>("query")
        {
            Description = "Search term to find packages in the Arch User Repository", Arity = ArgumentArity.OneOrMore
        };

        var command = new Command("search", "Search the Arch User Repository")
        {
            query
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Search
            {
                Query = parseResult.GetValue(query) ?? Array.Empty<string>()
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        var query = string.Join(" ", Query);

        if (string.IsNullOrWhiteSpace(query))
        {
            console.WriteLine(AnsiUtilities.Colorize("Query cannot be empty.", ConsoleColor.Red));
            return;
        }

        if (query.Length < 2)
        {
            console.WriteLine(AnsiUtilities.Colorize("Error: Query must be at least 2 characters long",
                ConsoleColor.Red));
            return;
        }

        using var manager = new AurPackageManager();
        await manager.Initialize();

        var results = await manager.SearchPackages(query);

        if (UiMode || JsonOutput)
        {
            JsonPackFrame.WriteToStdout(results);
            return;
        }

        console.WriteLine(BasicTable.Execute(
            ["Name", "Version", "Maintainer", "Last Updated", "Description"], results.Take(25).ToList(),
            p => p.Name,
            p => p.Version,
            p => p.Maintainer ?? "Unknown Maintainer",
            p => DateTimeOffset.FromUnixTimeSeconds(p.LastModified).ToString("yyyy-MM-dd HH:mm:ss"),
            p => Truncate(p.Description ?? "", 60)));
        console.WriteLine(AnsiUtilities.Colorize($"Total results: {results.Count}", ConsoleColor.Blue));
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;

    private static string Truncate(string value, int max) =>
        value.Length <= max ? value : value[..max];
}