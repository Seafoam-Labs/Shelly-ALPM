namespace Shelly.Cli.Commands;

public interface IShellyConsole
{
    TextWriter Output { get; }
    bool IsOutputRedirected { get; }
    void Write(string text);
    void WriteLine(string text);
    void WriteLine();
}

public sealed class SystemShellyConsole : IShellyConsole
{
    public TextWriter Output => Console.Out;
    public bool IsOutputRedirected => Console.IsOutputRedirected;
    public void Write(string text) => Console.Out.Write(text);
    public void WriteLine(string text) => Console.Out.WriteLine(text);
    public void WriteLine() => Console.Out.WriteLine();
}
