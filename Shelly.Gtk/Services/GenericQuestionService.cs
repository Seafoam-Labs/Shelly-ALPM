using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Services;

public class GenericQuestionService : IGenericQuestionService
{
    public event EventHandler<GenericQuestionEventArgs>? Question;

    public void RaiseQuestion(GenericQuestionEventArgs args)
    {
        Question?.Invoke(this, args);
    }
}
