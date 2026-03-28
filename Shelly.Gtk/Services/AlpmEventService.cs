using Shelly.Gtk.UiModels;
namespace Shelly.Gtk.Services;
public class AlpmEventService : IAlpmEventService
{
    public event EventHandler<QuestionEventArgs>? Question;
    public event EventHandler<PackageOperationEventArgs>? PackageOperation;
    public void RaiseQuestion(QuestionEventArgs args)
    {
        Question?.Invoke(this, args);
    }
    public void RaisePackageOperation(PackageOperationEventArgs args)
    {
        PackageOperation?.Invoke(this, args);
    }
}
