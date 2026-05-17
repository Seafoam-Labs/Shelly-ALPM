using System.Text.Json;
using PackageManager.Flatpak;
using PackageManager.Wire;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakListUpdatesCommand : Command<DefaultSettings>
{
    public override int Execute(CommandContext context, DefaultSettings settings)
    {
        if (Program.IsUiMode)
        {
            return HandleUiModeListUpdates(settings);
        }

        var packages = FlatpakManager.GetPackagesWithUpdates(true);

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
        table.AddColumn("Permissions");

        foreach (var pkg in packages.OrderBy(p => p.Id))
        {
            var permissions = pkg.Permissions.Count > 0
                ? string.Join("\n", pkg.Permissions)
                : "[grey]No changes[/]";

            table.AddRow(
                pkg.Name,
                pkg.Id,
                pkg.Version,
                permissions
            );
        }

        AnsiConsole.Write(table);
        AnsiConsole.MarkupLine($"[blue]Total: packages[/]");
        return 0;
    }

    private static int HandleUiModeListUpdates(DefaultSettings settings)
    {
        var packages = FlatpakManager.GetPackagesWithUpdates(true);

        if (settings.JsonOutput)
        {
            JsonPackFrame.WriteToStdout(packages);
            return 0;
        }

        foreach (var pkg in packages.OrderBy(p => p.Id))
        {
            Console.WriteLine($"{pkg.Name} {pkg.Id} {pkg.Version}");
        }

        Console.Error.WriteLine("Total: packages");
        return 0;
    }
}