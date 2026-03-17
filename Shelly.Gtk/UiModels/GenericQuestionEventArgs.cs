namespace Shelly.Gtk.UiModels;

public class GenericQuestionEventArgs(string title, string message, bool useMonospaceMessage = false) : EventArgs
{
    private readonly TaskCompletionSource<bool> _tcs = new();
    public Task<bool> ResponseTask => _tcs.Task;

    public string Title { get; } = title;
    public string Message { get; } = message;
    public bool UseMonospaceMessage { get; } = useMonospaceMessage;

    public void SetResponse(bool response)
    {
        _tcs.TrySetResult(response);
    }
}
