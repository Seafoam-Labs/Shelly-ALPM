using System.Text.Json;
using PackageManager;
using PackageManager.Alpm.Pacfile;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard.Pacfile;

public class PacfileCommand : AsyncCommand<PacfileSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, PacfileSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiMode(context, settings);
        }

        RootElevator.EnsureRootExectuion();
        var pacfileStoragePath = ShellyDatastore.GetPacfileStoragePath();
        await using PacfileManager manager = new(pacfileStoragePath);
        if (settings.Pacfiles.Length == 0)
        {
            //Running for all
            if (settings.Delete)
            {
                //Todo: Implement delete at later date once we better understand needed duration of retention
                return 0;
            }

            var result = await manager.GetPacfiles();
            if (settings.Json)
            {
                var serializedResult = JsonSerializer.Serialize(result, ShellyCLIJsonContext.Default.ListPacfileRecord);
                Console.WriteLine(serializedResult);
                return 0;
            }

            AnsiConsole.MarkupLine($"[blue]Pacfiles:[/]");
            Table table = new();
            table.AddColumns("Name", "Content");
            foreach (var pacfile in result)
            {
                table.AddRow(pacfile.Name,
                    pacfile.Text.Truncate(pacfile.Text.Length > 100 ? 100 : pacfile.Text.Length));
            }

            AnsiConsole.Write(table);
            return 0;
        }

        List<PacfileRecord?> records = [];
        foreach (var file in settings.Pacfiles)
        {
            records.Add(await manager.GetPacfile(file));
        }

        if (settings.Json)
        {
            var json = JsonSerializer.Serialize(records, ShellyCLIJsonContext.Default.ListPacfileRecord);
            await using var stdout = Console.OpenStandardOutput();
            await using var writer = new System.IO.StreamWriter(stdout, System.Text.Encoding.UTF8);
            await writer.WriteLineAsync(json);
            await writer.FlushAsync();
            return 0;
        }

        if (records.Count > 1)
        {
            AnsiConsole.MarkupLine($"[blue]Pacfiles:[/]");
            Table tableOutput = new();
            tableOutput.AddColumns("Name", "Content");
            foreach (var pacfile in records.Where(p => p is not null))
            {
                tableOutput.AddRow(pacfile!.Name,
                    pacfile.Text.Truncate(pacfile.Text.Length > 100 ? 100 : pacfile.Text.Length));
            }

            AnsiConsole.Write(tableOutput);
        }

        var record = records.FirstOrDefault(p => p is not null);
        if (record is not null)
        {
            AnsiConsole.MarkupLine($"[blue]{record.Name}[/]");
            AnsiConsole.WriteLine(record.Text);
            return 0;
        }

        AnsiConsole.MarkupLine("[red]Pacfile not found.[/]");
        return 0;
    }

    private async Task<int> HandleUiMode(CommandContext context, PacfileSettings settings)
    {
        var pacfileStoragePath = ShellyDatastore.GetPacfileStoragePath();
        await using PacfileManager manager = new(pacfileStoragePath);
        if (settings.Pacfiles.Length == 0)
        {
            if (settings.Delete)
            {
                return 0;
            }

            var result = await manager.GetPacfiles();
            Shelly_CLI.Utility.UiFrames.Frame(result);
            Shelly_CLI.Utility.UiFrames.Info($"Pacfiles: {result.Count}");
            return 0;
        }

        List<PacfileRecord> records = [];
        foreach (var file in settings.Pacfiles)
        {
            var record = await manager.GetPacfile(file);
            if (record is not null) records.Add(record);
        }

        Shelly_CLI.Utility.UiFrames.Frame(records);
        Shelly_CLI.Utility.UiFrames.Info($"Pacfiles found: {records.Count} of {settings.Pacfiles.Length}");
        return 0;
    }
}