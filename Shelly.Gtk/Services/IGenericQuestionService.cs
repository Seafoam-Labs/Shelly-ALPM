using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Services;

public interface IGenericQuestionService
{
    event EventHandler<GenericQuestionEventArgs>? Question;
    void RaiseQuestion(GenericQuestionEventArgs args);
}
