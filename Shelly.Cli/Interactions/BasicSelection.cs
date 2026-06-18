using Pastel;

namespace Shelly.Cli.Interactions;

public static class BasicSelection
{
    public static int Execute(string title, IReadOnlyList<string> options, int defaultIndex = 0)
    {
        if (options.Count == 0)
        {
            Console.WriteLine("No options available.".Pastel(ConsoleColor.Green));
            return defaultIndex;
        }
        defaultIndex = Math.Clamp(defaultIndex, 0, options.Count - 1);
        var supportAnsi = AnsiUtilities.SupportsAnsi;
        
        Console.WriteLine(supportAnsi ? $"{title.Pastel(ConsoleColor.DarkYellow)}" : $"{title} ({options[defaultIndex]})");

        for (var i = 0; i < options.Count; i++)
        {
            var option = options[i];
            var label = supportAnsi ? $"{i}. {option}".Pastel(ConsoleColor.Green) : $"{i}. {option}";
            Console.WriteLine(label);
        }
        var prompt = supportAnsi ? "Enter selection: ".Pastel(ConsoleColor.Yellow) : "Enter selection: ";
        while (true)
        {
            Console.Write(prompt);
            Console.Out.Flush();
            var input = Console.ReadLine();
            if (string.IsNullOrWhiteSpace(input))
            {
                return defaultIndex;
            }
            if (int.TryParse(input.Trim(), out var n) && n >= 1 && n <= options.Count)
                return n - 1;

            Console.WriteLine($"Please enter a number between 1 and {options.Count}.");
        }
    }
}