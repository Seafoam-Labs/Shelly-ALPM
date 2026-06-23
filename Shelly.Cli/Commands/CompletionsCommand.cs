using System.CommandLine;
using Shelly.Cli.Completions;

namespace Shelly.Cli.Commands;

public static class CompletionsCommand
{
    public static Command Create()
    {
        var shell = new Argument<string>("shell")
        {
            Description = "The shell to generate completions for (fish, zsh)"
        };

        var command = new Command("completions", "Generate shell completion scripts")
        {
            Hidden = true
        };
        command.Add(shell);

        command.SetAction(parseResult =>
        {
            var shellName = parseResult.GetValue(shell) ?? string.Empty;
            var root = Program.BuildRootCommand();
            try
            {
                var script = CompletionScript.Generate(shellName, root, "shelly");
                Console.Out.Write(script);
                return 0;
            }
            catch (ArgumentException ex)
            {
                Console.Error.WriteLine(ex.Message);
                return 1;
            }
        });

        return command;
    }
}
