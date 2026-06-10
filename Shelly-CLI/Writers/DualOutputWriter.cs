using System.Text;

namespace Shelly.Writers;

public class DualOutputWriter : TextWriter
{
    private readonly TextWriter _primary;
    private readonly TextWriter _stderr;
    private const string ShellyPrefix = "";

    public DualOutputWriter(TextWriter primary, TextWriter stderr)
    {
        _primary = primary;
        _stderr = stderr;
    }

    public override void WriteLine(string? value)
    {
        _primary.WriteLine(value);
        // Also write to stderr with prefix for UI capture
        _stderr.WriteLine($"{ShellyPrefix}{value}");
        _stderr.Flush();
    }

    public override void Write(string? value)
    {
        _primary.Write(value);
    }

    public override void Write(char value)
    {
        _primary.Write(value);
    }

    public override void Flush()
    {
        _primary.Flush();
        _stderr.Flush();
    }

    public override Encoding Encoding => _primary.Encoding;
}
