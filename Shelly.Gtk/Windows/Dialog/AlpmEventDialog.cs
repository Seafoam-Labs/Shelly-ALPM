using Gtk;
using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Windows.Dialog;

public class AlpmEventDialog
{
    public static void ShowAlpmEventDialog(Overlay parentOverlay, QuestionEventArgs e)
    {

        var box = Box.New(Orientation.Vertical, 12);
        box.SetHalign(Align.Center);
        box.SetValign(Align.Center);
        box.SetSizeRequest(450, -1);
        box.SetMarginTop(20);
        box.SetMarginBottom(20);
        box.SetMarginStart(20);
        box.SetMarginEnd(20);
        box.AddCssClass("dialog-overlay");

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

            var selectButton = Button.NewWithLabel("Select");
            selectButton.OnClicked += (s, args) =>
            {
                e.SetResponse(combo.GetActive());
                parentOverlay.RemoveOverlay(box);
            };
            buttonBox.Append(selectButton);
        }
        else
        {
            var noButton = Button.NewWithLabel("No");
            noButton.OnClicked += (s, args) =>
            {
                e.SetResponse(0); 
                parentOverlay.RemoveOverlay(box);
            };

            var yesButton = Button.NewWithLabel("Yes");
            yesButton.SetCssClasses(["suggested-action"]);
            yesButton.OnClicked += (s, args) =>
            {
                e.SetResponse(1); 
                parentOverlay.RemoveOverlay(box);
            };

            buttonBox.Append(noButton);
            buttonBox.Append(yesButton);
        }

        box.Append(buttonBox);
        parentOverlay.AddOverlay(box);
    }

    private static string GetQuestionTitle(QuestionType type) => type switch
    {
        QuestionType.InstallIgnorePkg => "Install Ignored Package?",
        QuestionType.ReplacePkg => "Replace Package?",
        QuestionType.ConflictPkg => "Package Conflict Detected",
        QuestionType.CorruptedPkg => "Corrupted Package Found",
        QuestionType.ImportKey => "Import PGP Key?",
        QuestionType.SelectProvider => "Select Provider",
        QuestionType.RemovePkgs => "Remove Packages?",
        _ => "System Question"
    };
}
