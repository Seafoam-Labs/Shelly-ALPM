namespace Shelly.Cli.Commands;

public abstract class GlobalSettingsCommand
{
    public bool NoConfirm { get; set; }

    public bool UiMode { get; set; }

    public bool JsonOutput { get; set; }

    public bool Verbose { get; set; }

    public abstract ValueTask ExecuteAsync(IShellyConsole console);

    public abstract ValueTask ExecuteUiMode();
}
