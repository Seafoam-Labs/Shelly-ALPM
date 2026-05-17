using System.Text.Json.Serialization;
using Shelly.Gtk.UiModels.Recommend;

namespace Shelly.Gtk.UiModels.Recommend;

[JsonSourceGenerationOptions(WriteIndented = true, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(List<RecommendModel>))]
internal partial class RecommendJsonContext : JsonSerializerContext
{
}
