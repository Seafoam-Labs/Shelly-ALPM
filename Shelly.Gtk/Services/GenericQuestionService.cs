using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Services;

public class GenericQuestionService : IGenericQuestionService
{
    public event EventHandler<GenericQuestionEventArgs>? Question;
    public event EventHandler<PackageBuildEventArgs>? PackageBuildRequested;
    public event EventHandler<GenericDialogEventArgs>? Dialog;
    
    public event EventHandler<ToastMessageEventArgs>? ToastMessageRequested;

    public void RaiseQuestion(GenericQuestionEventArgs args)
    {
        Question?.Invoke(this, args);
    }

    public void RaisePackageBuild(PackageBuildEventArgs args)
    {
        PackageBuildRequested?.Invoke(this, args);
    }

    public void RaiseDialog(GenericDialogEventArgs args)
    {
        Dialog?.Invoke(this, args);
    }
    
    public void RaiseToastMessage(ToastMessageEventArgs args)
    {
        ToastMessageRequested?.Invoke(this, args);
    }
}
