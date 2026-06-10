using System.Text.Json.Serialization;

namespace PackageManager.Alpm.DistributionHooks.CachyOS;

public record NoticeDto(
    [property:  JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("body")] string Body);