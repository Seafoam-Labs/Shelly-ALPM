using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Shelly.Utilities.Eventing;

[JsonPolymorphic(TypeDiscriminatorPropertyName = "$kind")]
[JsonDerivedType(typeof(PkgbuildDiffQuestionDto), "q.pkgbuilddiff")]
[JsonDerivedType(typeof(YesNoQuestionDto), "q.yesno")]
[JsonDerivedType(typeof(SelectProviderQuestionDto), "q.provider")]
[JsonDerivedType(typeof(SelectOptDepsQuestionDto), "q.optdeps")]
public abstract record QuestionRequest(string QuestionId);

public sealed record PkgbuildDiffQuestionDto(
    string QuestionId,
    string PackageName,
    string? OldPkgbuild,
    string NewPkgbuild,
    List<PkgbuildWarningDto>? Warnings,
    List<string>? DiffLines = null) : QuestionRequest(QuestionId);

public sealed record PkgbuildWarningDto(
    string Tool,
    string Severity,
    string Hook,
    string MatchedLine,
    string Message);

public sealed record ProviderOptionDto(
    int Index,
    string Name,
    string? Description,
    bool IsInstalled,
    bool IsSelected);

public sealed record YesNoQuestionDto(
    string QuestionId,
    string QuestionKind,
    string QuestionText) : QuestionRequest(QuestionId);

public sealed record SelectProviderQuestionDto(
    string QuestionId,
    string DependencyName,
    List<ProviderOptionDto> Options) : QuestionRequest(QuestionId);

public sealed record SelectOptDepsQuestionDto(
    string QuestionId,
    string DependencyName,
    List<ProviderOptionDto> Options) : QuestionRequest(QuestionId);

[JsonPolymorphic(TypeDiscriminatorPropertyName = "$kind")]
[JsonDerivedType(typeof(PkgbuildDiffAnswer), "a.pkgbuilddiff")]
[JsonDerivedType(typeof(YesNoAnswer), "a.yesno")]
[JsonDerivedType(typeof(SelectProviderAnswer), "a.provider")]
[JsonDerivedType(typeof(SelectOptDepsAnswer), "a.optdeps")]
public abstract record QuestionResponseDto(string QuestionId);

public sealed record PkgbuildDiffAnswer(
    string QuestionId,
    bool ProceedWithUpdate) : QuestionResponseDto(QuestionId);

public sealed record YesNoAnswer(
    string QuestionId,
    bool Accept) : QuestionResponseDto(QuestionId);

public sealed record SelectProviderAnswer(
    string QuestionId,
    int SelectedIndex) : QuestionResponseDto(QuestionId);

public sealed record SelectOptDepsAnswer(
    string QuestionId,
    List<int> SelectedIndices) : QuestionResponseDto(QuestionId);
