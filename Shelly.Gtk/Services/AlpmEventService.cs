using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Services;

public class AlpmEventService : IAlpmEventService
{
    public event EventHandler<QuestionEventArgs>? Question;
    public event EventHandler<PackageOperationEventArgs>? PackageOperation;
    public event EventHandler<string>? StdoutReceived;
    public event EventHandler<string>? StderrReceived;

    public void RaiseQuestion(QuestionEventArgs args)
    {
        Question?.Invoke(this, args);
    }

    public void RaisePackageOperation(PackageOperationEventArgs args)
    {
        PackageOperation?.Invoke(this, args);
    }

    public void RaiseStdoutReceived(string message)
    {
        StdoutReceived?.Invoke(this, message);
    }

    public void RaiseStderrReceived(string message)
    {
        StderrReceived?.Invoke(this, message);
    }
}