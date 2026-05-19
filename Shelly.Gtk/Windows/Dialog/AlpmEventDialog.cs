using Gtk;
using Shelly.Gtk.UiModels;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Windows.Dialog;

public class AlpmEventDialog
{
    public static void ShowAlpmEventDialog(Overlay parentOverlay, QuestionEventArgs e)
    {

        var baseFrame = Frame.New(null);
        baseFrame.SetHalign(Align.Center);
        baseFrame.SetValign(Align.Center);
        baseFrame.SetSizeRequest(450, -1);
        baseFrame.SetMarginTop(20);
        baseFrame.SetMarginBottom(20);
        baseFrame.SetMarginStart(20);
        baseFrame.SetMarginEnd(20);
        baseFrame.AddCssClass("background");
        baseFrame.AddCssClass("dialog-overlay");
        baseFrame.SetOverflow(Overflow.Hidden);

        var box = Box.New(Orientation.Vertical, 12);
        baseFrame.SetChild(box);

        var titleLabel = Label.New(string.Empty);
        titleLabel.SetMarkup($"<b>{GetQuestionTitle(e.QuestionType)}</b>");
        titleLabel.SetHalign(Align.Start);
        box.Append(titleLabel);

        var questionLabel = Label.New(e.QuestionText);
        questionLabel.SetWrap(true);
        questionLabel.SetHalign(Align.Start);
        questionLabel.SetXalign(0);
        box.Append(questionLabel);

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);
        buttonBox.SetMarginTop(10);

        if (e is { QuestionType: QuestionType.SelectProvider, ProviderOptions: not null })
        {
            var combo = ComboBoxText.New();
            foreach (var option in e.ProviderOptions)
            {
                combo.AppendText(option);
            }
            combo.SetActive(0);
            box.Append(combo);

            var selectButton = Button.NewWithLabel(T("Select"));
            selectButton.OnClicked += (_,_) =>
            {
                e.SetResponse(combo.GetActive());
                parentOverlay.RemoveOverlay(baseFrame);
            };
            buttonBox.Append(selectButton);
        }
        else if (e is { QuestionType: QuestionType.SelectOptionalDeps, ProviderOptions: not null })
        {
            var checkButtons = new List<CheckButton>();

            // "Select All" toggle
            var selectAllCheck = CheckButton.NewWithLabel(T("Select All"));
            box.Append(selectAllCheck);

            // Scrollable container for many options
            var scrolled = ScrolledWindow.New();
            scrolled.SetMinContentHeight(150);
            scrolled.SetMaxContentHeight(300);
            scrolled.SetPolicy(PolicyType.Never, PolicyType.Automatic);

            var optionsBox = Box.New(Orientation.Vertical, 4);
            foreach (var option in e.ProviderOptions)
            {
                var check = CheckButton.NewWithLabel(option);
                check.SetActive(true); // default all selected
                checkButtons.Add(check);
                optionsBox.Append(check);
            }
            scrolled.SetChild(optionsBox);
            box.Append(scrolled);

            // Wire up "Select All" toggle
            selectAllCheck.SetActive(true);
            selectAllCheck.OnToggled += (_,_) =>
            {
                var active = selectAllCheck.GetActive();
                foreach (var cb in checkButtons)
                {
                    cb.SetActive(active);
                }
            };

            var confirmButton = Button.NewWithLabel(T("Confirm"));
            confirmButton.SetCssClasses(["suggested-action"]);
            confirmButton.OnClicked += (_,_) =>
            {
                int bitmask = 0;
                for (int i = 0; i < checkButtons.Count; i++)
                {
                    if (checkButtons[i].GetActive())
                    {
                        bitmask |= (1 << i);
                    }
                }
                e.SetResponse(bitmask);
                parentOverlay.RemoveOverlay(baseFrame);
            };
            buttonBox.Append(confirmButton);
        }
        else
        {
            var noButton = Button.NewWithLabel(T("No"));
            noButton.OnClicked += (_,_) =>
            {
                e.SetResponse(0); 
                parentOverlay.RemoveOverlay(baseFrame);
            };

            var yesButton = Button.NewWithLabel(T("Yes"));
            yesButton.SetCssClasses(["suggested-action"]);
            yesButton.OnClicked += (_,_) =>
            {
                e.SetResponse(1); 
                parentOverlay.RemoveOverlay(baseFrame);
            };

            buttonBox.Append(yesButton);
            buttonBox.Append(noButton);
          
        }

        box.Append(buttonBox);
        parentOverlay.AddOverlay(baseFrame);
    }

    private static string GetQuestionTitle(QuestionType type) => type switch
    {
        QuestionType.InstallIgnorePkg => T("Install Ignored Package?"),
        QuestionType.ReplacePkg => T("Replace Package?"),
        QuestionType.ConflictPkg => T("Package Conflict Detected"),
        QuestionType.CorruptedPkg => T("Corrupted Package Found"),
        QuestionType.ImportKey => T("Import PGP Key?"),
        QuestionType.SelectProvider => T("Select Provider"),
        QuestionType.RemovePkgs => T("Remove Packages?"),
        QuestionType.SelectOptionalDeps => T("Select Optional Dependencies"),
        _ => T("System Question")
    };
}
