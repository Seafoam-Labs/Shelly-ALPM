using PackageManager.Local;
using PackageManager.Wire;
using Shelly.Utilities.Eventing;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class RemoveLocalCommand : AsyncCommand<PackageSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, PackageSettings settings)
    {
        if (Program.IsUiMode) return await HandleUiModeRemove(settings);

        RootElevator.EnsureRootExectuion();

        AnsiConsole.MarkupLine(
            $"[yellow]Packages to remove:[/] {string.Join(", ", settings.Packages.Select(p => p.EscapeMarkup()))}");

        if (!settings.NoConfirm && !AnsiConsole.Confirm("Do you want to proceed?"))
        {
            AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
            return 0;
        }

        var localManager = new LocalManager();

        localManager.Message += (_, e) =>
        {
            switch (e.Level)
            {
                case LocalManagerMessageLevel.Info:
                    AnsiConsole.MarkupLine($"[cyan]{e.Message.EscapeMarkup()}[/]");
                    break;
                case LocalManagerMessageLevel.Warning:
                    AnsiConsole.MarkupLine($"[yellow]{e.Message.EscapeMarkup()}[/]");
                    break;
                case LocalManagerMessageLevel.Error:
                    AnsiConsole.MarkupLine($"[red]{e.Message.EscapeMarkup()}[/]");
                    break;
                case LocalManagerMessageLevel.Success:
                    AnsiConsole.MarkupLine($"[green]{e.Message.EscapeMarkup()}[/]");
                    break;
            }
        };

        var success = await localManager.RemoveBinaryPackages(settings.Packages.ToList());
        return success ? 0 : 1;
    }

    private static async Task<int> HandleUiModeRemove(PackageSettings settings)
    {
        var localManager = new LocalManager();

        localManager.Message += (_, e) =>
        {
            switch (e.Level)
            {
                case LocalManagerMessageLevel.Info:
                case LocalManagerMessageLevel.Success:
                    JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                        AlpmEvents.InformationalOutput, e.Message));
                    break;
                case LocalManagerMessageLevel.Warning:
                    JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                        AlpmEvents.InformationalOutput, $"Warning: {e.Message}"));
                    break;
                case LocalManagerMessageLevel.Error:
                    JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, e.Message));
                    break;
            }
        };

        var success = await localManager.RemoveBinaryPackages(settings.Packages.ToList());
        return success ? 0 : 1;
    }
}