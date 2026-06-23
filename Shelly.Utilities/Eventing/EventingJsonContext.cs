using System.Text.Json.Serialization;

namespace Shelly.Utilities.Eventing;

[JsonSourceGenerationOptions(
    MaxDepth = 256,
    GenerationMode = JsonSourceGenerationMode.Default,
    UseStringEnumConverter = true)]
[JsonSerializable(typeof(AlpmErrorEvent))]
[JsonSerializable(typeof(AlpmHookEvent))]
[JsonSerializable(typeof(AlpmScriptletEvent))]
[JsonSerializable(typeof(AlpmReplaceEvent))]
[JsonSerializable(typeof(AlpmPackageProgressEvent))]
[JsonSerializable(typeof(AlpmStatusEvent))]
[JsonSerializable(typeof(AlpmInformationalEvent))]
[JsonSerializable(typeof(AlpmEvents))]
[JsonSerializable(typeof(EventSource))]
[JsonSerializable(typeof(EventLevel))]
[JsonSerializable(typeof(Event))]
[JsonSerializable(typeof(QuestionRequest))]
[JsonSerializable(typeof(QuestionResponseDto))]
[JsonSerializable(typeof(PkgbuildDiffQuestionDto))]
[JsonSerializable(typeof(PkgbuildWarningDto))]
[JsonSerializable(typeof(PkgbuildDiffAnswer))]
[JsonSerializable(typeof(ProviderOptionDto))]
[JsonSerializable(typeof(YesNoQuestionDto))]
[JsonSerializable(typeof(SelectProviderQuestionDto))]
[JsonSerializable(typeof(SelectOptDepsQuestionDto))]
[JsonSerializable(typeof(YesNoAnswer))]
[JsonSerializable(typeof(SelectProviderAnswer))]
[JsonSerializable(typeof(SelectOptDepsAnswer))]
[JsonSerializable(typeof(List<ProviderOptionDto>))]
[JsonSerializable(typeof(List<int>))]
[JsonSerializable(typeof(List<string>))]
public partial class EventingJsonContext : JsonSerializerContext;