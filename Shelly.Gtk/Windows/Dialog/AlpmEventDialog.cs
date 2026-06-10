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
                var label = option.IsInstalled
                    ? $"{option.Name}  ({T("installed")})"
                    : option.Name;
                combo.AppendText(label);
            }

            var preselect = e.ProviderOptions.FindIndex(o => o.IsSelected);
            combo.SetActive(preselect >= 0 ? preselect : 0);

            void UpdateTooltip()
            {
                var idx = combo.GetActive();
                if (idx >= 0 && idx < e.ProviderOptions.Count)
                    combo.SetTooltipText(e.ProviderOptions[idx].Description ?? string.Empty);
            }
            UpdateTooltip();
            combo.OnChanged += (_, _) => UpdateTooltip();

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
            var originalIndices = new List<int>();

            var selectAllCheck = CheckButton.NewWithLabel(T("Select All"));

            var scrolled = ScrolledWindow.New();
            scrolled.SetMinContentHeight(150);
            scrolled.SetMaxContentHeight(300);
            scrolled.SetPolicy(PolicyType.Never, PolicyType.Automatic);

            var optionsBox = Box.New(Orientation.Vertical, 4);
            for (var i = 0; i < e.ProviderOptions.Count; i++)
            {
                var option = e.ProviderOptions[i];

                if (option.IsInstalled)
                {
                    var row = Box.New(Orientation.Horizontal, 6);
                    row.SetMarginStart(6);
                    row.SetMarginTop(4);
                    row.SetMarginBottom(4);
                    row.Append(Image.NewFromIconName("object-select-symbolic"));
                    row.Append(Label.New($"{option.Name} ({T("already installed")})"));
                    if (!string.IsNullOrEmpty(option.Description))
                        row.SetTooltipText(option.Description);
                    optionsBox.Append(row);
                    continue;
                }

                var check = CheckButton.NewWithLabel(option.Name);
                check.SetActive(option.IsSelected);
                if (!string.IsNullOrEmpty(option.Description))
                    check.SetTooltipText(option.Description);

                checkButtons.Add(check);
                originalIndices.Add(i);
                optionsBox.Append(check);
            }

            if (checkButtons.Count == 0)
            {
                e.SetResponse(Array.Empty<int>());
                return;
            }

            box.Append(selectAllCheck);
            scrolled.SetChild(optionsBox);
            box.Append(scrolled);

            selectAllCheck.SetActive(false);
            selectAllCheck.OnToggled += (_,_) =>
            {
                var active = selectAllCheck.GetActive();
                foreach (var cb in checkButtons) cb.SetActive(active);
            };

            var confirmButton = Button.NewWithLabel(T("Confirm"));
            confirmButton.SetCssClasses(["suggested-action"]);
            confirmButton.OnClicked += (_,_) =>
            {
                var selectedIndices = new List<int>();
                for (int v = 0; v < checkButtons.Count; v++)
                {
                    if (checkButtons[v].GetActive())
                    {
                        selectedIndices.Add(originalIndices[v]);
                    }
                }
                e.SetResponse(selectedIndices.ToArray());
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
