using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PackageManager.Flatpak;

/// <summary>
/// JSON serialization context for Appstream types (AOT-compatible)
/// </summary>
[JsonSerializable(typeof(AppstreamApp))]
[JsonSerializable(typeof(List<AppstreamApp>))]
[JsonSerializable(typeof(AppstreamIcon))]
[JsonSerializable(typeof(AppstreamScreenshot))]
[JsonSerializable(typeof(AppstreamImage))]
[JsonSerializable(typeof(AppstreamRelease))]
[JsonSerializable(typeof(FlatpakRemoteRefInfo))]
public partial class AppstreamJsonContext : JsonSerializerContext
{
}
