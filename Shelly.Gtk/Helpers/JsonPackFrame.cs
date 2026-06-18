using System;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using Shelly.Utilities.Eventing;

namespace Shelly.Gtk.Helpers;

/// <summary>
/// JSON wire-frame matching the Shelly-CLI writer side. Decodes <c>[MEMPACK]…[/MEMPACK]</c>
/// envelopes whose payload is base64-encoded UTF-8 JSON, deserialized via the
/// <see cref="ShellyGtkJsonContext"/> source-generated context (AOT-safe).
/// </summary>
public static class JsonPackFrame
{
    public const string Prefix = "[JSON]";
    public const string Suffix = "[/JSON]";

    public static bool TryExtractPayload(string output, out string base64)
    {
        base64 = string.Empty;
        if (string.IsNullOrWhiteSpace(output)) return false;
        var pref = output.IndexOf(Prefix, StringComparison.Ordinal);
        if (pref < 0) return false;
        var suff = output.IndexOf(Suffix, pref + Prefix.Length, StringComparison.Ordinal);
        if (suff < 0) return false;
        base64 = output.Substring(pref + Prefix.Length, suff - (pref + Prefix.Length));
        return true;
    }

    public static bool TryDecodePayload<T>(string base64, out T? value)
    {
        value = default;
        try
        {
            var bytes = Convert.FromBase64String(base64);
            var json = Encoding.UTF8.GetString(bytes);
            var info = EventingJsonContext.Default.GetTypeInfo(typeof(T))
                ?? ShellyGtkJsonContext.Default.GetTypeInfo(typeof(T))
                ?? throw new InvalidOperationException(
                    $"No [JsonSerializable] entry for {typeof(T)} in EventingJsonContext or ShellyGtkJsonContext.");
            var typeInfo = (JsonTypeInfo<T>)info;
            value = JsonSerializer.Deserialize(json, typeInfo);
            return value is not null;
        }
        catch
        {
            return false;
        }
    }

    public static string EncodePayload<T>(T value)
    {
        var info = EventingJsonContext.Default.GetTypeInfo(typeof(T))
            ?? ShellyGtkJsonContext.Default.GetTypeInfo(typeof(T))
            ?? throw new InvalidOperationException(
                $"No [JsonSerializable] entry for {typeof(T)} in EventingJsonContext or ShellyGtkJsonContext.");
        var typeInfo = (JsonTypeInfo<T>)info;
        var json = JsonSerializer.Serialize(value, typeInfo);
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
    }

    public static string EncodeFrame<T>(T value) => $"{Prefix}{EncodePayload(value)}{Suffix}";

    /// <summary>
    /// Decodes the <b>last</b> <c>[JSON]…[/JSON]</c> frame in the output. Use this when the writer
    /// emits multiple frames (e.g. progress/informational events first and the real payload last),
    /// as <c>check-updates --ui-mode</c> does.
    /// </summary>
    public static bool TryDecodeLast<T>(string output, out T? value)
    {
        value = default;
        if (string.IsNullOrWhiteSpace(output)) return false;

        var pref = output.LastIndexOf(Prefix, StringComparison.Ordinal);
        if (pref < 0) return false;
        var suff = output.IndexOf(Suffix, pref + Prefix.Length, StringComparison.Ordinal);
        if (suff < 0) return false;
        var payload = output.Substring(pref + Prefix.Length, suff - (pref + Prefix.Length));

        return TryDecodePayload(payload, out value);
    }

    public static bool TryDecode<T>(string output, out T? value)
    {
        value = default;
        if (string.IsNullOrWhiteSpace(output)) return false;

        var pref = output.IndexOf(Prefix, StringComparison.Ordinal);
        if (pref < 0) return false;
        var suff = output.IndexOf(Suffix, pref + Prefix.Length, StringComparison.Ordinal);
        if (suff < 0) return false;
        var payload = output.AsSpan(pref + Prefix.Length, suff - (pref + Prefix.Length));

        try
        {
            var bytes = Convert.FromBase64String(payload.ToString());
            var json = Encoding.UTF8.GetString(bytes);
            var info = EventingJsonContext.Default.GetTypeInfo(typeof(T))
                ?? ShellyGtkJsonContext.Default.GetTypeInfo(typeof(T))
                ?? throw new InvalidOperationException(
                    $"No [JsonSerializable] entry for {typeof(T)} in EventingJsonContext or ShellyGtkJsonContext. " +
                    $"Add [JsonSerializable(typeof({typeof(T).Name}))] to one of those contexts.");
            var typeInfo = (JsonTypeInfo<T>)info;
            value = JsonSerializer.Deserialize(json, typeInfo);
            return value is not null;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[MemPackFrame] decode failed: {ex.Message} (len={payload.Length})");
            return false;
        }
    }
}
