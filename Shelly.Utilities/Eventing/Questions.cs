using System.Text.Json.Serialization;

namespace Shelly.Utilities.Eventing;

[JsonPolymorphic(TypeDiscriminatorPropertyName = "$kind")]
[JsonDerivedType(typeof(PkgbuildDiffQuestionDto), "q.pkgbuilddiff")]
public abstract record QuestionRequest(string QuestionId);

public sealed record PkgbuildDiffQuestionDto(
    string QuestionId,
    string PackageName,
    string OldPkgbuild,
    string NewPkgbuild) : QuestionRequest(QuestionId);

[JsonPolymorphic(TypeDiscriminatorPropertyName = "$kind")]
[JsonDerivedType(typeof(PkgbuildDiffAnswer), "a.pkgbuilddiff")]
public abstract record QuestionResponseDto(string QuestionId);

public sealed record PkgbuildDiffAnswer(
    string QuestionId,
    bool ProceedWithUpdate) : QuestionResponseDto(QuestionId);
