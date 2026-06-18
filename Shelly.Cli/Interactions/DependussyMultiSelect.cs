using PackageManager.Alpm.Questions;
using Pastel;

namespace Shelly.Cli.Interactions;

public static class DependussyMultiSelect
{
    /// <summary>
    /// Execute the multi-select prompt.
    /// </summary>
    /// <param name="title"></param>
    /// <param name="options"></param>
    /// <returns></returns>
    public static IList<ProviderOption> Execute(
        string title,
        IReadOnlyList<ProviderOption> options)
    {
        var ansiSupport = AnsiUtilities.SupportsAnsi;
        if (options.Count == 0)
        {
            Console.WriteLine(ansiSupport ? "No options available.".Pastel(ConsoleColor.Red) : "No options available.");
            return [];
        }

        Console.WriteLine(ansiSupport ? title.Pastel(ConsoleColor.DarkYellow) : title);

        for (var i = 0; i < options.Count; i++)
        {
            var marker = options[i].IsInstalled ? "[X]" : "[ ]";
            var label = ansiSupport
                ? $"{i + 1}. {marker} {options[i].Name} : {options[i].Description}".Pastel(ConsoleColor.Green)
                : $"{i + 1}. {marker} {options[i].Name} : {options[i].Description}";
            Console.WriteLine(label);
        }

        var hint = ansiSupport
            ? "Enter numbers separated by space (e.g. 1 3): ".Pastel(ConsoleColor.Yellow)
            : "Enter numbers separated by space (e.g. 1 3): ";

        while (true)
        {
            Console.Write(hint);
            Console.Out.Flush();
            var input = Console.ReadLine();
            if (string.IsNullOrWhiteSpace(input))
            {
                return options.Select(option =>
                    new ProviderOption(option.Name, option.Description, option.IsInstalled, false)).ToList();
            }

            var selectedIndices = input
                .Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .Select(s => int.TryParse(s, out var n) ? n - 1 : -1) // 1-based → 0-based
                .Where(n => n >= 0 && n < options.Count)
                .ToHashSet();
            if (selectedIndices.Count > 0)
            {
                return options
                    .Select((o, i) => o with { IsSelected = selectedIndices.Contains(i) })
                    .ToList();
            }

            Console.WriteLine(ansiSupport
                ? "Invalid input. Please try again.".Pastel(ConsoleColor.Red)
                : "Invalid input. Please try again.");
        }
    }
}