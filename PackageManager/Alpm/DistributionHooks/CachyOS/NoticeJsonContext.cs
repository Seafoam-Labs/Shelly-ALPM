using System.Text.Json.Serialization;

namespace PackageManager.Alpm.DistributionHooks.CachyOS;

[JsonSerializable(typeof(NoticeDto))]
public partial class NoticeJsonContext : JsonSerializerContext;
