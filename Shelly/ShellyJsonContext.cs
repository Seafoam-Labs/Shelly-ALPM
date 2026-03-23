using System.Text.Json.Serialization;
using PackageManager.Alpm;
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
internal partial class ShellyJsonContext : JsonSerializerContext
{
    
}
