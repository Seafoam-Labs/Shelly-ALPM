using System.Text;
using System.Text.RegularExpressions;

namespace Shelly.Writers;

/// <summary>
/// A TextWriter that filters out lines containing [bracketed] patterns when running in terminal mode.
/// </summary>
public class FilteringTextWriter : TextWriter
{
    private readonly TextWriter _inner;
    private static readonly Regex BracketedPattern = new Regex(@"\[[^\]]+\]", RegexOptions.Compiled);

    public FilteringTextWriter(TextWriter inner)
    {
        _inner = inner;
    }

    public override void WriteLine(string? value)
    {
        // Filter out lines that contain [somestring] patterns
        if (value != null && BracketedPattern.IsMatch(value))
        {
            return; // Skip this line
        }

        _inner.WriteLine(value);
        _inner.Flush();
    }

    public override void Write(string? value)
    {
        // For Write (without newline), pass through as-is since we filter on complete lines
        _inner.Write(value);
        _inner.Flush();
    }

    public override void Write(char value)
    {
        _inner.Write(value);
    }

    public override Encoding Encoding => _inner.Encoding;
}
