namespace Shelly.Gtk.UiModels;

public class ToastMessageEventArgs(string title) : EventArgs
{
    public string Title { get; } = title;
}