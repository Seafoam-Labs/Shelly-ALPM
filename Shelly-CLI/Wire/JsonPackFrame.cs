using System;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;

namespace PackageManager.Wire;

/// <summary>
/// JSON wire-frame used to exchange typed payloads between Shelly-CLI (writer) and Shelly.Gtk (reader).
/// Uses <c>[MEMPACK]…[/MEMPACK]</c> markers for backwards compatibility with existing call-sites,
/// but the payload between the markers is base64-encoded UTF-8 JSON produced by the
/// <see cref="Shelly_CLI.ShellyCLIJsonContext"/> source-generated serializer (AOT-safe).
/// </summary>
public static class JsonPackFrame
{
    public const string Prefix = "[JSON]";
    public const string Suffix = "[/JSON]";

    public static void WriteToStdout<T>(T value)
    {
        var info = Shelly_CLI.ShellyCLIJsonContext.Default.GetTypeInfo(typeof(T))
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
}
