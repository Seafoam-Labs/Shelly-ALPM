using Shelly.Gtk.UiModels;
namespace Shelly.Gtk.Services;
public interface IAlpmEventService
{
    event EventHandler<QuestionEventArgs>? Question;
    event EventHandler<PackageOperationEventArgs>? PackageOperation;
    /// <summary>
    /// Raises a Question event. Called by PrivilegedOperationService when parsing CLI stderr.
    /// </summary>
    void RaiseQuestion(QuestionEventArgs args);
    /// <summary>
    /// Raises a PackageOperation event. Called by PrivilegedOperationService when parsing CLI stderr.
    /// </summary>
    void RaisePackageOperation(PackageOperationEventArgs args);
}
