using Gtk;

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

            var box = Box.New(Orientation.Vertical, 12);
            box.SetHalign(Align.Center);
            box.SetValign(Align.Center);
            box.SetHexpand(true);
            box.SetVexpand(true);
            box.SetSizeRequest(500, 400);
            box.SetMarginTop(20);
            box.SetMarginBottom(20);
            box.SetMarginStart(20);
            box.SetMarginEnd(20);
            box.AddCssClass("dialog-overlay");
            _background.Append(box);

            _descriptionLabel = Label.New(description);
            _descriptionLabel.SetWrap(true);
            _descriptionLabel.SetHalign(Align.Center);
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
            _consoleOutput.SetWrapMode(WrapMode.WordChar);
            scrolledWindow.SetChild(_consoleOutput);

            box.Append(scrolledWindow);

            _closeButton = Button.NewWithLabel("Close");
            _closeButton.SetHalign(Align.Center);
            _closeButton.SetVisible(false);
            _closeButton.OnClicked += (_, _) => Hide();
            box.Append(_closeButton);
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
        buffer.GetEndIter(out var endIter);
        buffer.Insert(endIter, logLine + "\n", -1);
        if (_consoleOutput.GetRealized())
        {
            buffer.GetEndIter(out var newEnd);
            buffer.PlaceCursor(newEnd);
            var mark = buffer.GetInsert();
            _consoleOutput.ScrollToMark(mark, 0, false, 0, 0);
        }
    }

    public void ShowCloseButton()
    {
        _operationComplete = true;
        _closeButton?.SetVisible(true);
        _descriptionLabel?.SetText("Operation Complete");
        _progressBar?.SetFraction(1.0);
    }

    public void Hide()
    {
        if (_background != null && _parentOverlay != null && IsVisible)
        {
            _parentOverlay.RemoveOverlay(_background);
        }
        _consoleOutput?.Buffer.SetText("", 0);
        _operationComplete = false;
        _closeButton?.SetVisible(false);
    }
}
