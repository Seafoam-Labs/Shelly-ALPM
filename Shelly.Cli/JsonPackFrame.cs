using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli;

/// <summary>
/// JSON wire-frame used to exchange typed payloads between Shelly-CLI (writer) and Shelly.Gtk (reader).
/// Uses <c>[MEMPACK]…[/MEMPACK]</c> markers for backwards compatibility with existing call-sites,
/// but the payload between the markers is base64-encoded UTF-8 JSON produced by the
/// <see cref="ShellyCliJsonContext"/> source-generated serializer (AOT-safe).
/// </summary>
public static class JsonPackFrame
{
    public const string Prefix = "[JSON]";
    public const string Suffix = "[/JSON]";

    public static void WriteToStdout<T>(T value)
    {
        var info = EventingJsonContext.Default.GetTypeInfo(typeof(T)) ??
                   ShellyCliJsonContext.Default.GetTypeInfo(typeof(T))
                   ?? throw new InvalidOperationException(
                       $"ShellyCLIJsonContext has no [JsonSerializable] entry for {typeof(T)}. " +
                       $"Add [JsonSerializable(typeof({typeof(T).Name}))] to Shelly-CLI/ShellyCLIJsonContext.cs.");
        var typeInfo = (JsonTypeInfo<T>)info;
        var json = JsonSerializer.Serialize(value, typeInfo);
        var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
        using var stdout = Console.OpenStandardOutput();
        using var writer = new StreamWriter(stdout, new UTF8Encoding(false));
        writer.Write(Prefix);
        writer.Write(encoded);
        writer.Write(Suffix);
        writer.Write('\n');
        writer.Flush();
    }

    /// <summary>
    /// Reads a single framed payload from stdin and deserializes it as <typeparamref name="T"/>.
    /// Blocks until a line containing <see cref="Prefix"/>…<see cref="Suffix"/> is read.
    /// Used by the question pipeline for bidirectional request/response over stdin/stdout.
    /// </summary>
    public static T ReadFromStdin<T>()
    {
        string? line;
        while ((line = Console.In.ReadLine()) != null)
        {
            var start = line.IndexOf(Prefix, StringComparison.Ordinal);
            if (start < 0) continue;
            start += Prefix.Length;
            var end = line.IndexOf(Suffix, start, StringComparison.Ordinal);
            if (end < 0) continue;
            var b64 = line.Substring(start, end - start);
            var json = Encoding.UTF8.GetString(Convert.FromBase64String(b64));
            var info = EventingJsonContext.Default.GetTypeInfo(typeof(T))
                       ?? ShellyCliJsonContext.Default.GetTypeInfo(typeof(T))
                       ?? throw new InvalidOperationException(
                           $"No JsonTypeInfo for {typeof(T)} in EventingJsonContext or ShellyCLIJsonContext.");
            return JsonSerializer.Deserialize(json, (JsonTypeInfo<T>)info)!;
        }
        throw new EndOfStreamException("stdin closed while awaiting framed payload");
    }
}