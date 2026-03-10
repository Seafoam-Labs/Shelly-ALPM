using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Services;

public interface IGenericQuestionService
{
    event EventHandler<GenericQuestionEventArgs>? Question;
    event EventHandler<PackageBuildEventArgs>? PackageBuildRequested;
    
    event EventHandler<ToastMessageEventArgs>? ToastMessageRequested;
    void RaiseQuestion(GenericQuestionEventArgs args);
    void RaisePackageBuild(PackageBuildEventArgs args);
    void RaiseToastMessage(ToastMessageEventArgs args);
}
