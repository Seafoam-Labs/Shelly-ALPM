using System.Text.Json.Serialization;
using PackageManager.Alpm;
using PackageManager.Aur.Models;
using Shelly.Commands.AurCommands;
using Shelly.Commands.StandardCommands;
using Shelly.Configurations;
using Shelly.Models;

namespace Shelly;

[JsonSerializable(typeof(SyncModel))]
[JsonSerializable(typeof(SyncPackageModel))]
[JsonSerializable(typeof(SyncAurModel))]
[JsonSerializable(typeof(SyncFlatpakModel))]
[JsonSerializable(typeof(ShellyConfig))]
[JsonSerializable(typeof(List<AlpmPackageDto>))]
[JsonSerializable(typeof(List<AlpmPackageUpdateDto>))]
[JsonSerializable(typeof(List<ArchNewsCommands.RssModel>))]
[JsonSerializable(typeof(List<AurPackageDto>))]
[JsonSerializable(typeof(List<AurUpdateDto>))]
[JsonSerializable(typeof(List<AurSearchPackageBuildCommands.PackageBuild>))]
internal partial class ShellyJsonContext : JsonSerializerContext
{
    
}
