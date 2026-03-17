using System.Diagnostics.CodeAnalysis;
using PackageManager.Alpm;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;
namespace Shelly_CLI.Commands.Standard;
public class ListReposCommand : Command
{
    public override int Execute([NotNull] CommandContext context)
    {
        var repos = AlpmManager.GetRepositories();
        if (Program.IsUiMode)
        {
            foreach (var repo in repos)
            {
                Console.WriteLine(repo);
            }
            return 0;
        }
        var table = new Table();
        table.AddColumn("#");
        table.AddColumn("Repository");
        for (var i = 0; i < repos.Count; i++)
        {
            table.AddRow((i + 1).ToString(), repos[i]);
        }
        AnsiConsole.Write(table);
        AnsiConsole.MarkupLine($"[blue]Total: {repos.Count} repositories[/]");
        return 0;
    }
}
