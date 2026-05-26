using System.Text.Json.Serialization;
using PackageManager.AppImage;
using PackageManager.Alpm;
using PackageManager.Alpm.Pacfile;
using PackageManager.Alpm.Questions;
using PackageManager.Aur.Models;
using PackageManager.Flatpak;
using PackageManager.Local;
using Shelly_CLI.Commands.Aur.Models;
using Shelly_CLI.Commands.Standard.Models;
using Shelly_CLI.Configuration;
using Shelly.Utilities;

namespace Shelly_CLI;

[JsonSourceGenerationOptions(
    MaxDepth = 256,
    GenerationMode = JsonSourceGenerationMode.Default)]
[JsonSerializable(typeof(List<AlpmPackageUpdateDto>))]
[JsonSerializable(typeof(AlpmPackageUpdateDto))]
[JsonSerializable(typeof(List<AlpmPackageDto>))]
[JsonSerializable(typeof(AlpmPackageDto))]
[JsonSerializable(typeof(List<LocalPackageDto>))]
[JsonSerializable(typeof(LocalPackageDto))]
[JsonSerializable(typeof(List<AurPackageDto>))]
[JsonSerializable(typeof(AurPackageDto))]
[JsonSerializable(typeof(List<AurUpdateDto>))]
[JsonSerializable(typeof(AurUpdateDto))]
[JsonSerializable(typeof(SyncModel))]
[JsonSerializable(typeof(SyncPackageModel))]
[JsonSerializable(typeof(SyncAurModel))]
[JsonSerializable(typeof(SyncFlatpakModel))]
[JsonSerializable(typeof(RssModel))]
[JsonSerializable(typeof(List<RssModel>))]
[JsonSerializable(typeof(List<AppImageDto>))]
[JsonSerializable(typeof(AppImageDto))]
[JsonSerializable(typeof(List<AppImageUpdateDto>))]
[JsonSerializable(typeof(AppImageUpdateDto))]
[JsonSerializable(typeof(ShellyConfig))]
[JsonSerializable(typeof(List<FlatpakPackageDto>))]
[JsonSerializable(typeof(FlatpakPackageDto))]
[JsonSerializable(typeof(List<FlatpakRemoteDto>))]
[JsonSerializable(typeof(FlatpakRemoteDto))]
[JsonSerializable(typeof(List<PacfileRecord>))]
[JsonSerializable(typeof(PacfileRecord))]
[JsonSerializable(typeof(PackageBuild))]
[JsonSerializable(typeof(FlatpakRemoteRefInfo))]
[JsonSerializable(typeof(List<AppstreamApp>))]
[JsonSerializable(typeof(AppstreamApp))]
[JsonSerializable(typeof(AppstreamIcon))]
[JsonSerializable(typeof(List<AppstreamIcon>))]
[JsonSerializable(typeof(AppstreamScreenshot))]
[JsonSerializable(typeof(List<AppstreamScreenshot>))]
[JsonSerializable(typeof(AppstreamImage))]
[JsonSerializable(typeof(List<AppstreamImage>))]
[JsonSerializable(typeof(AppstreamRelease))]
[JsonSerializable(typeof(List<AppstreamRelease>))]
[JsonSerializable(typeof(PackageBuild))]
[JsonSerializable(typeof(List<PackageBuild>))]
[JsonSerializable(typeof(ProviderOption))]
[JsonSerializable(typeof(List<ProviderOption>))]
[JsonSerializable(typeof(QuestionResponse))]
[JsonSerializable(typeof(int[]))]
internal partial class ShellyCLIJsonContext : JsonSerializerContext;