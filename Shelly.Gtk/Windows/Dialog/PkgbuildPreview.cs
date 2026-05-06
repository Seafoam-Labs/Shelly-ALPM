using Gtk;
using Pango;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using WrapMode = Gtk.WrapMode;

namespace Shelly.Gtk.Windows.Dialog;

public static class PkgbuildPreview
{
    public static void ShowPackageBuildPreview(Overlay parentOverlay, PackageBuildEventArgs e, IGenericQuestionService questionService)
    {
        var background = Box.New(Orientation.Horizontal, 0);
        background.AddCssClass("lockout-overlay");
        background.SetHalign(Align.Fill);
        background.SetValign(Align.Fill);
        background.SetHexpand(true);
        background.SetVexpand(true);

        var baseFrame = Frame.New(null);
        baseFrame.SetHalign(Align.Center);
        baseFrame.SetValign(Align.Center);
        baseFrame.SetSizeRequest(900, 600); 
        baseFrame.SetMarginTop(20);
        baseFrame.SetMarginBottom(20);
        baseFrame.SetMarginStart(20);
        baseFrame.SetMarginEnd(20);
        baseFrame.AddCssClass("background");
        baseFrame.AddCssClass("dialog-overlay");
        baseFrame.SetOverflow(Overflow.Hidden);
        background.Append(baseFrame);

        var box = Box.New(Orientation.Vertical, 12);
        baseFrame.SetChild(box);

        var headerBox = Box.New(Orientation.Horizontal, 0);
        headerBox.SetMarginTop(4);
        headerBox.SetMarginStart(4);

        var closeButton = Button.New();
        closeButton.SetIconName("window-close-symbolic");
        closeButton.TooltipText = "Close Preview";
        closeButton.OnClicked += (_, _) => Close();
        
        var copyButton = Button.New();
        copyButton.SetIconName("edit-copy-symbolic"); 
        copyButton.TooltipText = "Copy PKGBUILD to clipboard";
        copyButton.OnClicked += (_, _) =>
        {
            var clipboard = copyButton.GetClipboard();
            clipboard.SetText(e.PkgBuild);
            questionService.RaiseToastMessage(new ToastMessageEventArgs("PKGBUILD copied to clipboard"));
        };

        var titleLabel = Label.New(e.Title);
        titleLabel.AddCssClass("title-4");
        titleLabel.SetHexpand(true);
        titleLabel.SetHalign(Align.Center);
        titleLabel.SetXalign(0.5f);
        titleLabel.SetMarginEnd(40);

        headerBox.Append(copyButton);
        headerBox.Append(titleLabel);
        headerBox.Append(closeButton);

        box.Append(headerBox);
        

        var textView = TextView.New();
        textView.SetWrapMode(WrapMode.WordChar);
        textView.Editable = false;          
        textView.Monospace = true;        
        textView.CursorVisible = false;
        textView.LeftMargin = 12;
        textView.RightMargin = 12;
        textView.TopMargin = 12;
        textView.BottomMargin = 12;
        
        textView.GetBuffer().SetText(e.PkgBuild, -1);

        var scrolledWindow = ScrolledWindow.New();
        scrolledWindow.SetPolicy(PolicyType.Automatic, PolicyType.Automatic);
        scrolledWindow.SetVexpand(true);
        scrolledWindow.SetHexpand(true);
        scrolledWindow.AddCssClass("view"); 
        scrolledWindow.SetChild(textView);
        
        box.Append(scrolledWindow);

        var shortcutController = ShortcutController.New();
        shortcutController.Scope = ShortcutScope.Global;
        
        var escAction = CallbackAction.New((_, _) => {
            Close();
            return true;
        });
        shortcutController.AddShortcut(Shortcut.New(ShortcutTrigger.ParseString("Escape"), escAction));
        background.AddController(shortcutController);

        parentOverlay.AddOverlay(background);
        return;

        void Close()
        {
            e.SetResponse(false);
            parentOverlay.RemoveOverlay(background);
        }
    }
}