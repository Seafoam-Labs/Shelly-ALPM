using PackageManager.Alpm;
namespace Shelly.Commands.StandardCommands;

internal static class ListReposCommands
{
    internal static int ListReposUiMode()
    {
        var repos = AlpmManager.GetRepositories();
        foreach (var repo in repos)
        {
            Console.WriteLine(repo);
        }
        return 0;
    }

    internal static int ListReposConsoleMode()
    {
        var repos = AlpmManager.GetRepositories();
        for (var i = 0; i < repos.Count; i++)
        {
            Console.WriteLine($"{i + 1}. {repos[i]}");
        }
        Console.WriteLine($"Total: {repos.Count} repositories");
        return 0;
    }
}
