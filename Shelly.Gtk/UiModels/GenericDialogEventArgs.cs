using Gtk;

namespace Shelly.Gtk.UiModels;

public class GenericDialogEventArgs(Box box)
{
    private readonly TaskCompletionSource<bool> _tcs = new();
    public Task<bool> ResponseTask => _tcs.Task;

    public Box Box { get; } = box;

    public void SetResponse(bool response)
    {
        _tcs.TrySetResult(response);
    }
}