namespace Shelly.Gtk.UiModels;

public class QuestionEventArgs(
    QuestionType questionType,
    string questionText,
    List<ProviderOptionUiModel>? providerOptions = null,
    string? dependencyName = null)
    : EventArgs
{
    private readonly TaskCompletionSource<int> _tcs = new();
    public Task<int> ResponseTask => _tcs.Task;

    public QuestionType QuestionType { get; } = questionType;
    public string QuestionText { get; } = questionText;
    public List<ProviderOptionUiModel>? ProviderOptions { get; } = providerOptions;
    public string? DependencyName { get; } = dependencyName;
    public int Response { get; private set; } = -1;

    /// <summary>
    /// For SelectOptionalDeps: indices of options the user selected (empty == none).
    /// Null for non-multi-select questions.
    /// </summary>
    public int[]? SelectedIndices { get; private set; }

    public void SetResponse(int response)
    {
        Response = response;
        _tcs.TrySetResult(response);
    }

    /// <summary>
    /// Sets the response for a multi-select question (SelectOptionalDeps).
    /// </summary>
    public void SetResponse(int[] selectedIndices)
    {
        SelectedIndices = selectedIndices;
        Response = 0;
        _tcs.TrySetResult(0);
    }

    public Task WaitForResponseAsync()
    {
        return _tcs.Task;
    }
}
