using System.Reflection;
using Shelly.Keys.Commands.Initialize;
using Spectre.Console.Cli;

namespace Shelly.Keys;

internal class Program
{
    public static bool KeyServer { get; set; } = false;

    public static int Main(string[] args)
    {
        var app = new CommandApp();
        app.Configure(config =>
        {
            config.SetApplicationName("shelly-keys");
            config.SetApplicationVersion(Assembly.GetExecutingAssembly().GetName().Version?.ToString(4) ?? "unknown");

            config.AddCommand<InitializeCommand>("initialize")
                .WithDescription("Initialize gpg keys")
                .WithExample("initialize")
                .WithExample("initialize", "/etc/pacman.d/gnupg")
                .WithAlias("--init")
                .WithAlias("-i")
                .WithAlias("init");
        });
        var result = app.Run(args);
        return result;
    }
}