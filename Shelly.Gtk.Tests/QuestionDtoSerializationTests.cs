using Shelly.Gtk.Helpers;
using Shelly.Utilities.Eventing;

namespace Shelly.Gtk.Tests;

[TestFixture]
public class QuestionDtoSerializationTests
{
    [Test]
    public void YesNoQuestionDto_RoundTrips_WithMultilineNonAsciiText()
    {
        var text = "Replace package?\nДа/Нет — \u26A0 conflict with foo\u001Fbar";
        var original = new YesNoQuestionDto("id-1", "ConflictPkg", text);

        var frame = JsonPackFrame.EncodeFrame<QuestionRequest>(original);

        Assert.That(JsonPackFrame.TryDecode<QuestionRequest>(frame, out var decoded), Is.True);
        var dto = decoded as YesNoQuestionDto;
        Assert.That(dto, Is.Not.Null);
        Assert.That(dto!.QuestionId, Is.EqualTo("id-1"));
        Assert.That(dto.QuestionKind, Is.EqualTo("ConflictPkg"));
        Assert.That(dto.QuestionText, Is.EqualTo(text));
    }

    [Test]
    public void SelectProviderQuestionDto_RoundTrips()
    {
        var original = new SelectProviderQuestionDto(
            "id-2",
            "java-runtime",
            [
                new ProviderOptionDto(0, "jre-openjdk", "OpenJDK", false, false),
                new ProviderOptionDto(1, "jre17-openjdk", null, true, true),
            ]);

        var frame = JsonPackFrame.EncodeFrame<QuestionRequest>(original);

        Assert.That(JsonPackFrame.TryDecode<QuestionRequest>(frame, out var decoded), Is.True);
        var dto = decoded as SelectProviderQuestionDto;
        Assert.That(dto, Is.Not.Null);
        Assert.That(dto!.DependencyName, Is.EqualTo("java-runtime"));
        Assert.That(dto.Options, Has.Count.EqualTo(2));
        Assert.That(dto.Options[0].Name, Is.EqualTo("jre-openjdk"));
        Assert.That(dto.Options[1].IsInstalled, Is.True);
        Assert.That(dto.Options[1].IsSelected, Is.True);
        Assert.That(dto.Options[1].Description, Is.Null);
    }

    [Test]
    public void SelectOptDepsQuestionDto_RoundTrips()
    {
        var original = new SelectOptDepsQuestionDto(
            "id-3",
            "some-pkg",
            [
                new ProviderOptionDto(0, "opt-a", "desc a", false, true),
                new ProviderOptionDto(1, "opt-b", "desc b", true, false),
            ]);

        var frame = JsonPackFrame.EncodeFrame<QuestionRequest>(original);

        Assert.That(JsonPackFrame.TryDecode<QuestionRequest>(frame, out var decoded), Is.True);
        var dto = decoded as SelectOptDepsQuestionDto;
        Assert.That(dto, Is.Not.Null);
        Assert.That(dto!.DependencyName, Is.EqualTo("some-pkg"));
        Assert.That(dto.Options, Has.Count.EqualTo(2));
        Assert.That(dto.Options[0].IsSelected, Is.True);
    }

    [Test]
    public void YesNoAnswer_RoundTrips()
    {
        var original = new YesNoAnswer("id-1", true);

        var frame = JsonPackFrame.EncodeFrame<QuestionResponseDto>(original);

        Assert.That(JsonPackFrame.TryDecode<QuestionResponseDto>(frame, out var decoded), Is.True);
        var dto = decoded as YesNoAnswer;
        Assert.That(dto, Is.Not.Null);
        Assert.That(dto!.QuestionId, Is.EqualTo("id-1"));
        Assert.That(dto.Accept, Is.True);
    }

    [Test]
    public void SelectProviderAnswer_RoundTrips()
    {
        var original = new SelectProviderAnswer("id-2", 3);

        var frame = JsonPackFrame.EncodeFrame<QuestionResponseDto>(original);

        Assert.That(JsonPackFrame.TryDecode<QuestionResponseDto>(frame, out var decoded), Is.True);
        var dto = decoded as SelectProviderAnswer;
        Assert.That(dto, Is.Not.Null);
        Assert.That(dto!.SelectedIndex, Is.EqualTo(3));
    }

    [Test]
    public void SelectOptDepsAnswer_RoundTrips()
    {
        var original = new SelectOptDepsAnswer("id-3", [0, 2, 5]);

        var frame = JsonPackFrame.EncodeFrame<QuestionResponseDto>(original);

        Assert.That(JsonPackFrame.TryDecode<QuestionResponseDto>(frame, out var decoded), Is.True);
        var dto = decoded as SelectOptDepsAnswer;
        Assert.That(dto, Is.Not.Null);
        Assert.That(dto!.SelectedIndices, Is.EqualTo(new List<int> { 0, 2, 5 }));
    }
}
