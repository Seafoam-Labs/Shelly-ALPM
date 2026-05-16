using System.Text.Json;
using PackageManager.Flatpak;
using PackageManager.Wire;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakListCommand : Command<DefaultSettings>
{
    public override int Execute(CommandContext context, DefaultSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeList(settings);
        }

        var manager = new FlatpakManager();

        var packages = manager.SearchInstalled();

        if (settings.JsonOutput)
        {
            var json = JsonSerializer.Serialize(packages, ShellyCLIJsonContext.Default.ListFlatpakPackageDto);
            using var stdout = Console.OpenStandardOutput();
            using var writer = new StreamWriter(stdout, System.Text.Encoding.UTF8);
            writer.WriteLine(json);
            writer.Flush();
            return 0;
        }

        var table = new Table();
        table.AddColumn("Name");
        table.AddColumn("Id");
        table.AddColumn("Version");
        table.AddColumn("Arch");
        table.AddColumn("Branch");
        table.AddColumn("Summary");
        table.AddColumn("Remote");

        foreach (var pkg in packages.OrderBy(p => p.Id))
        {
            table.AddRow(
                pkg.Name,
                pkg.Id,
                pkg.Version,
                pkg.Arch,
                pkg.Version,
                pkg.Summary.EscapeMarkup().Truncate(50),
                pkg.Remote
            );
        }

        AnsiConsole.Write(table);
        AnsiConsole.MarkupLine($"[blue]Total: packages[/]");
        return 0;
    }

    private static int HandleUiModeList(DefaultSettings settings)
    {
        var manager = new FlatpakManager();

        var packages = manager.SearchInstalled();

        if (settings.JsonOutput)
        {
            JsonPackFrame.WriteToStdout(packages);
            return 0;
        }

        foreach (var pkg in packages.OrderBy(p => p.Id))
        {
            Console.WriteLine($"{pkg.Name} {pkg.Id} {pkg.Version} {pkg.Arch} {pkg.Version} - {pkg.Summary}");
        }

        Console.Error.WriteLine("Total: packages");
        return 0;
    }
}