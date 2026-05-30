namespace Shelly.Gtk.Services;

public interface IUpdateService
{
    public Task<string> PullReleaseNotesAsync();
}