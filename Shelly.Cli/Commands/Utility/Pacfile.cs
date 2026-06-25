using System.CommandLine;
using System.Text.Json;
using PackageManager;
using PackageManager.Alpm.Pacfile;
using static Shelly.Cli.Interactions.AnsiUtilities;
using static System.CommandLine.ArgumentArity;

namespace Shelly.Cli.Commands.Utility;

public class Pacfile : GlobalSettingsCommand
{
    private string[] Pacfiles { get; set; } = [];

    public static Command Create()
    {
        var pacfilesArgument = new Argument<string[]>("pacfiles")
        {
            Description = "Pacfile names, defaults to all pacfiles if not specified",
            Arity = ZeroOrMore
        };
        var command = new Command("pacfile", "Manage pacfiles")
        {
            pacfilesArgument
        };
        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Pacfile
            {
                Pacfiles = parseResult.GetValue(pacfilesArgument) ?? []
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

        var records = await FetchRecordsAsync();
        RenderConsoleAsync(console, records);
    }

    public override async ValueTask ExecuteUiMode()
    {
        var records = await FetchRecordsAsync();
        UiFrames.Frame(records);
    }

    private async ValueTask<List<PacfileRecord>> FetchRecordsAsync()
    {
        var pacfileStoragePath = ShellyDatastore.GetPacfileStoragePath();
        await using PacfileManager manager = new(pacfileStoragePath);

        if (Pacfiles.Length == 0) return await manager.GetPacfiles();

        List<PacfileRecord> records = [];
        foreach (var file in Pacfiles)
        {
            var pacfile = await manager.GetPacfile(file);
            if (pacfile is not null)
                records.Add(pacfile);
        }

        return records;
    }

    private void RenderConsoleAsync(IShellyConsole console, List<PacfileRecord> records)
    {
        if (JsonOutput)
        {
            console.WriteLine(JsonSerializer.Serialize(records, ShellyCliJsonContext.Default.ListPacfileRecord));
            return;
        }

        switch (records.Count)
        {
            case 0:
                console.WriteLine(Colorize("Pacfile not found.", ConsoleColor.Yellow));
                break;
            case 1:
                var record = records[0];
                console.WriteLine(Colorize(record.Name, ConsoleColor.Blue));
                console.WriteLine(record.Text);
                break;
            default:
                RenderList(console, "Pacfiles:", records);
                break;
        }
    }

    private static void RenderList(IShellyConsole console, string header, List<PacfileRecord> records)
    {
        console.WriteLine(Colorize(header, ConsoleColor.Blue));

        foreach (var record in records)
        {
            console.WriteLine();
            console.WriteLine(Colorize($"--- {record.Name} ---", ConsoleColor.Cyan));
            console.WriteLine(record.Text.Length > 500 ? record.Text[..500] + Environment.NewLine + "..." : record.Text);
        }
    }
}