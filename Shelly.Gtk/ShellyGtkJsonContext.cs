using System.Text.Json.Serialization;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk;

[JsonSerializable(typeof(ShellyConfig))]
[JsonSerializable(typeof(CachedRssModel))]
[JsonSerializable(typeof(RssModel))]
[JsonSerializable(typeof(List<RssModel>))]
[JsonSerializable(typeof(GitHubRelease))]
[JsonSerializable(typeof(GitHubAsset))]
[JsonSerializable(typeof(GitHubAsset[]))]
[JsonSerializable(typeof(List<AlpmPackageUpdateDto>))]
[JsonSerializable(typeof(AlpmPackageUpdateDto))]
[JsonSerializable(typeof(List<AlpmPackageDto>))]
[JsonSerializable(typeof(AlpmPackageDto))]
[JsonSerializable(typeof(List<AurPackageDto>))]
[JsonSerializable(typeof(AurPackageDto))]
[JsonSerializable(typeof(List<AurUpdateDto>))]
[JsonSerializable(typeof(AurUpdateDto))]
[JsonSerializable(typeof(FlatpakModel))]
[JsonSerializable(typeof(List<FlatpakModel>))]
[JsonSerializable(typeof(SyncModel))]
[JsonSerializable(typeof(SyncPackageModel))]
[JsonSerializable(typeof(SyncAurModel))]
[JsonSerializable(typeof(SyncFlatpakModel))]
[JsonSerializable(typeof(List<PackageBuild>))]
[JsonSerializable(typeof(FlathubSearchResponse))]
[JsonSerializable(typeof(FlathubHit))]
[JsonSerializable(typeof(FlatpakPackageDto))]
[JsonSerializable(typeof(List<FlatpakPackageDto>))]
[JsonSerializable(typeof(List<AppstreamRelease>))]
[JsonSerializable(typeof(AppstreamRelease))]
[JsonSerializable(typeof(List<AppstreamApp>))]
[JsonSerializable(typeof(AppstreamApp))]
[JsonSerializable(typeof(FlatpakApiResponse))]
[JsonSerializable(typeof(Hit))]
[JsonSerializable(typeof(List<Hit>))]
[JsonSerializable(typeof(FlatpakRemoteRefInfo))]
[JsonSerializable(typeof(List<FlatpakRemoteRefInfo>))]
[JsonSerializable(typeof(FlatpakRemoteDto))]
internal partial class ShellyGtkJsonContext : JsonSerializerContext
{
    
}