using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Windows.Dialog;
using Shelly.Utilities.Eventing;
using Shelly.Utilities.Models;
using QuestionType = Shelly.Gtk.UiModels.QuestionType;
using QuestionEventArgs = Shelly.Gtk.UiModels.QuestionEventArgs;
using ProviderOptionUiModel = Shelly.Gtk.UiModels.ProviderOptionUiModel;


namespace Shelly.Gtk.Services.Wire;

internal static class QuestionRouter
{

    public static async Task<bool> TryDispatchAsync(string base64, Func<string,
            Task> writeFrame, IGenericQuestionService genericQuestionService,
        IAlpmEventService alpmEventService)
    {
        if (!JsonPackFrame.TryDecodePayload<QuestionRequest>(base64, out var req) || req is null)
            return false;

        QuestionResponseDto resp = req switch
        {
            PkgbuildDiffQuestionDto d => new PkgbuildDiffAnswer(
                d.QuestionId,
                await PromptPkgbuildDiffAsync(d)),
            YesNoQuestionDto q => new YesNoAnswer(
                q.QuestionId,
                await PromptYesNoAsync(q, alpmEventService)),
            SelectProviderQuestionDto q => new SelectProviderAnswer(
                q.QuestionId,
                await PromptProviderAsync(q, alpmEventService)),
            SelectOptDepsQuestionDto q => new SelectOptDepsAnswer(
                q.QuestionId,
                await PromptOptDepsAsync(q, alpmEventService)),
            _ => throw new InvalidOperationException($"Unhandled QuestionRequest {req.GetType()}")
        };

        var frame = JsonPackFrame.EncodeFrame<QuestionResponseDto>(resp);
        await writeFrame(frame);
        return true;
    }

    private static async Task<bool> PromptYesNoAsync(YesNoQuestionDto q, IAlpmEventService alpmEventService)
    {
        var type = Enum.TryParse<QuestionType>(q.QuestionKind, out var parsed)
            ? parsed
            : QuestionType.InstallIgnorePkg;

        var args = new QuestionEventArgs(type, q.QuestionText);
        alpmEventService.RaiseQuestion(args);
        await args.WaitForResponseAsync();
        return args.Response == 1;
    }

    private static async Task<int> PromptProviderAsync(SelectProviderQuestionDto q, IAlpmEventService alpmEventService)
    {
        var options = q.Options
            .Select(o => new ProviderOptionUiModel(o.Name, o.Description, o.IsInstalled, o.IsSelected))
            .ToList();

        var args = new QuestionEventArgs(
            QuestionType.SelectProvider,
            q.DependencyName,
            options,
            q.DependencyName);

        alpmEventService.RaiseQuestion(args);
        await args.WaitForResponseAsync();
        return args.Response < 0 ? 0 : args.Response;
    }

    private static async Task<List<int>> PromptOptDepsAsync(SelectOptDepsQuestionDto q, IAlpmEventService alpmEventService)
    {
        var options = q.Options
            .Select(o => new ProviderOptionUiModel(o.Name, o.Description, o.IsInstalled, o.IsSelected))
            .ToList();

        var args = new QuestionEventArgs(
            QuestionType.SelectOptionalDeps,
            q.DependencyName,
            options,
            q.DependencyName);

        alpmEventService.RaiseQuestion(args);
        await args.WaitForResponseAsync();
        return (args.SelectedIndices ?? []).ToList();
    }

    private static Task<bool> PromptPkgbuildDiffAsync(PkgbuildDiffQuestionDto d)
    {
        var warnings = d.Warnings ?? [];
        var diff = PkgbuildDiff.BuildLines(d.OldPkgbuild ?? string.Empty, d.NewPkgbuild ?? string.Empty);

        var tcs = new TaskCompletionSource<bool>();

        GLib.Functions.IdleAdd(0, () =>
        {
            var parent = (Gio.Application.GetDefault() as Application)?.GetActiveWindow();
            _ = PkgbuildReviewDialog.ShowAsync(parent, d.PackageName, diff, warnings)
                .ContinueWith(t => tcs.TrySetResult(t is { IsCompletedSuccessfully: true, Result: true }));
            return false;
        });

        return tcs.Task;
    }
}
