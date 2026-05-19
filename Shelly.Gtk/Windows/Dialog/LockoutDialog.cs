using Gtk;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Windows.Dialog;

public class LockoutDialog
{
    private Box? _background;
    private Label? _descriptionLabel;
    private ProgressBar? _progressBar;
    private TextView? _consoleOutput;
    private Button? _closeButton;
    private Overlay? _parentOverlay;
    private bool _operationComplete;

    public bool IsVisible => _background?.GetParent() != null;

    public void Show(Overlay parentOverlay, string description, double progress, bool isIndeterminate)
    {
        _parentOverlay = parentOverlay;

        if (_background == null)
        {
            _background = Box.New(Orientation.Vertical, 0);
            _background.AddCssClass("lockout-overlay");
            _background.SetHalign(Align.Fill);
            _background.SetValign(Align.Fill);

            var baseFrame = Frame.New(null);
            baseFrame.SetHalign(Align.Center);
            baseFrame.SetValign(Align.Center);
            baseFrame.SetHexpand(true);
            baseFrame.SetVexpand(true);
            baseFrame.SetSizeRequest(500, 400);
            baseFrame.SetMarginTop(20);
            baseFrame.SetMarginBottom(20);
            baseFrame.SetMarginStart(20);
            baseFrame.SetMarginEnd(20);
            baseFrame.AddCssClass("background");
            baseFrame.AddCssClass("dialog-overlay");
            baseFrame.SetOverflow(Overflow.Hidden);
            _background.Append(baseFrame);

            var box = Box.New(Orientation.Vertical, 12);
            baseFrame.SetChild(box);

            _descriptionLabel = Label.New(description);
            _descriptionLabel.SetWrap(true);
            _descriptionLabel.SetHalign(Align.Center);
            _descriptionLabel.SetWrap(true);
            _descriptionLabel.SetWrapMode(Pango.WrapMode.WordChar);
            _descriptionLabel.SetEllipsize(Pango.EllipsizeMode.None);
            _descriptionLabel.MaxWidthChars = 35;
            box.Append(_descriptionLabel);

            _progressBar = ProgressBar.New();
            _progressBar.SetShowText(true);
            _progressBar.SetHalign(Align.Fill);
            _progressBar.SetHexpand(true);
            box.Append(_progressBar);

            var scrolledWindow = ScrolledWindow.New();
            scrolledWindow.SetVexpand(true);
            scrolledWindow.SetHexpand(true);
            scrolledWindow.SetMinContentHeight(200);

            _consoleOutput = TextView.New();
            _consoleOutput.SetEditable(false);
            _consoleOutput.SetCursorVisible(false);
            _consoleOutput.SetMonospace(true);
            _consoleOutput.BottomMargin = 30;
            _consoleOutput.SetWrapMode(WrapMode.WordChar);
            scrolledWindow.SetChild(_consoleOutput);

            box.Append(scrolledWindow);

            _closeButton = Button.NewWithLabel(T("Close"));
            _closeButton.SetHalign(Align.Center);
            _closeButton.SetVisible(false);
            _closeButton.OnClicked += (_, _) => Hide();
            box.Append(_closeButton);

            var shortcutController = ShortcutController.New();
            shortcutController.Scope = ShortcutScope.Global;
            shortcutController.PropagationPhase = PropagationPhase.Capture;

            foreach (var triggerStr in new[] { "Return", "KP_Enter", "space", "Escape" })
            {
                var action = CallbackAction.New((_, _) =>
                {
                    if (!_operationComplete) return false;
                    Hide();
                    return true;
                });
                shortcutController.AddShortcut(Shortcut.New(ShortcutTrigger.ParseString(triggerStr), action));
            }

            _background.AddController(shortcutController);
        }

        _descriptionLabel!.SetText(description);
        _progressBar!.Fraction = progress / 100.0;
        if (isIndeterminate) _progressBar.Pulse();
        _closeButton!.SetVisible(false);
        _operationComplete = false;

        if (!IsVisible)
        {
            parentOverlay.AddOverlay(_background);
        }
    }

    public void UpdateStatus(string description, double progress, bool isIndeterminate)
    {
        _descriptionLabel?.SetText(description);
        if (_progressBar != null)
        {
            _progressBar.Fraction = progress / 100.0;
            if (isIndeterminate) _progressBar.Pulse();
        }
    }

    public void AppendLogLine(string logLine)
    {
        if (_consoleOutput == null || !IsVisible) return;
        var buffer = _consoleOutput.Buffer;
        if (buffer is null)
        {
            return;
        }

        buffer.GetEndIter(out var endIter);
        buffer.Insert(endIter, logLine + "\n", -1);
        if (!_consoleOutput.GetRealized()) return;
        buffer.GetEndIter(out var newEnd);
        buffer.PlaceCursor(newEnd);
        var mark = buffer.GetInsert();
        _consoleOutput.ScrollToMark(mark, 0, false, 0, 0);
    }

    public void ShowCloseButton()
    {
        _operationComplete = true;
        _closeButton?.SetVisible(true);
        _descriptionLabel?.SetText(T("Operation Complete"));
        _progressBar?.SetFraction(1.0);
    }

    public void Hide()
    {
        if (_background != null && _parentOverlay != null && IsVisible)
        {
            _parentOverlay.RemoveOverlay(_background);
        }

        _consoleOutput?.Buffer?.SetText("", 0);
        _operationComplete = false;
        _closeButton?.SetVisible(false);
    }
}