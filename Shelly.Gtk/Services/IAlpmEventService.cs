using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Services;

public interface IAlpmEventService
{
    event EventHandler<QuestionEventArgs>? Question;
    event EventHandler<PackageOperationEventArgs>? PackageOperation;
    event EventHandler<string>? StdoutReceived;
    event EventHandler<string>? StderrReceived;

    /// <summary>
    /// Raises a Question event. Called by PrivilegedOperationService when parsing CLI stderr.
    /// </summary>
    void RaiseQuestion(QuestionEventArgs args);

    /// <summary>
    /// Raises a PackageOperation event. Called by PrivilegedOperationService when parsing CLI stderr.
    /// </summary>
    void RaisePackageOperation(PackageOperationEventArgs args);

    void RaiseStdoutReceived(string message);
    void RaiseStderrReceived(string message);
}
