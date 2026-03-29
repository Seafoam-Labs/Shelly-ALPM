using Gtk;
using System.Text;
using System.Text.RegularExpressions;

namespace Shelly.Gtk.Windows.Dialog;

public static partial class ReleaseNotesDialog
{

    public class ReleaseItem
    {
        public string Version { get; set; } = string.Empty;
        public string Date { get; set; } = string.Empty;
        public string Markdown { get; set; } = string.Empty;    
    }
    
    public static void ShowReleaseNotesDialog(Overlay parentOverlay, string markdown)
    {
        var box = Box.New(Orientation.Vertical, 12);
        box.SetHalign(Align.Center);
        box.SetValign(Align.Center);
        box.SetSizeRequest(600, 500);
        box.SetMarginTop(40);
        box.SetMarginBottom(40);
        box.SetMarginStart(40);
        box.SetMarginEnd(40);
        box.AddCssClass("dialog-overlay");

        var titleLabel = Label.New("What's New");
        titleLabel.AddCssClass("title-2");
        box.Append(titleLabel);

        var contentBox = Box.New(Orientation.Vertical, 6);
        contentBox.SetMarginTop(10);
        contentBox.SetMarginBottom(10);
        contentBox.SetMarginStart(10);
        contentBox.SetMarginEnd(10);

        ParseMarkdown(contentBox, markdown);

        var scrolledWindow = new ScrolledWindow();
        scrolledWindow.SetPolicy(PolicyType.Never, PolicyType.Automatic);
        scrolledWindow.SetVexpand(true);
        scrolledWindow.SetChild(contentBox);
        box.Append(scrolledWindow);

        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);
        buttonBox.SetMarginTop(10);

        var closeButton = Button.NewWithLabel("Close");
        closeButton.AddCssClass("suggested-action");
        closeButton.OnClicked += (s, args) =>
        {
            parentOverlay.RemoveOverlay(box);
        };

        buttonBox.Append(closeButton);
        box.Append(buttonBox);

        parentOverlay.AddOverlay(box);
    }

    public static void ShowReleaseHistoryDialog(Overlay parentOverlay, List<ReleaseItem> releases)
    {
        var box = Box.New(Orientation.Vertical, 12);
        box.SetHalign(Align.Center);
        box.SetValign(Align.Center);
        box.SetSizeRequest(700, 550);
        box.SetMarginTop(40);
        box.SetMarginBottom(40);
        box.SetMarginStart(40);
        box.SetMarginEnd(40);
        box.AddCssClass("dialog-overlay");
        
        var titleLabel = Label.New("Version History");
        titleLabel.AddCssClass("title-2");
        box.Append(titleLabel);
        
        var contentBox = Box.New(Orientation.Vertical, 12);
        contentBox.SetMarginTop(10);
        contentBox.SetMarginBottom(10);
        contentBox.SetMarginStart(10);
        contentBox.SetMarginEnd(10);

        foreach (var release in releases)
        {
            contentBox.Append(BuildReleaseCard(release));
        }

        var scrolledWindow = new ScrolledWindow();
        scrolledWindow.SetPolicy(PolicyType.Never, PolicyType.Automatic);
        scrolledWindow.SetVexpand(true);
        scrolledWindow.SetChild(contentBox);
        box.Append(scrolledWindow);
        
        var buttonBox = Box.New(Orientation.Horizontal, 8);
        buttonBox.SetHalign(Align.End);
        buttonBox.SetMarginTop(10);
        
        var closeButton = Button.NewWithLabel("Close");
        closeButton.AddCssClass("suggested-action");
        closeButton.OnClicked += (s, args) =>
        {
            parentOverlay.RemoveOverlay(box);
        };

        buttonBox.Append(closeButton);
        box.Append(buttonBox);

        parentOverlay.AddOverlay(box);
        
    }
    
    private static void ParseMarkdown(Box container, string markdown)
    {
        var lines = markdown.Split('\n');
        foreach (var line in lines)
        {
            var trimmedLine = line.Trim();
            if (string.IsNullOrWhiteSpace(trimmedLine))
            {
                continue;
            }

            if (trimmedLine.StartsWith("## "))
            {
                var label = Label.New(string.Empty);
                label.SetMarkup($"<span size='large' weight='bold'>{GLib.Markup.EscapeText(trimmedLine[3..])}</span>");
                label.SetHalign(Align.Start);
                label.SetMarginTop(10);
                container.Append(label);
            }
            else if (trimmedLine.StartsWith("* "))
            {
                var label = Label.New(string.Empty);
                var content = ProcessInlineMarkdown(trimmedLine[2..]);
                label.SetMarkup($"• {content}");
                label.SetHalign(Align.Start);
                label.SetXalign(0);
                label.SetWrap(true);
                label.SetMarginStart(12);
                container.Append(label);
            }
            else
            {
                var label = Label.New(string.Empty);
                var content = ProcessInlineMarkdown(trimmedLine);
                label.SetMarkup(content);
                label.SetHalign(Align.Start);
                label.SetXalign(0);
                label.SetWrap(true);
                container.Append(label);
            }
        }
    }
    
    private static Box BuildReleaseCard(ReleaseItem release)
    {
        var card = Box.New(Orientation.Vertical, 8);
        card.AddCssClass("card");
        card.SetMarginBottom(6);
        card.SetMarginStart(2);
        card.SetMarginEnd(2);
        card.SetMarginTop(2);

        var header = Box.New(Orientation.Horizontal, 8);
        header.SetMarginTop(8);
        header.SetMarginBottom(4);
        header.SetMarginStart(8);
        header.SetMarginEnd(8);

        var versionLabel = Label.New($"Version {release.Version}");
        versionLabel.AddCssClass("heading");
        versionLabel.SetHalign(Align.Start);
        versionLabel.SetXalign(0);
        versionLabel.SetHexpand(true);

        var dateLabel = Label.New(release.Date);
        dateLabel.AddCssClass("dim-label");
        dateLabel.SetHalign(Align.End);
        dateLabel.SetValign(Align.Center);

        header.Append(versionLabel);
        header.Append(dateLabel);
        card.Append(header);

        var markdownBox = Box.New(Orientation.Vertical, 6);
        markdownBox.SetMarginBottom(8);
        markdownBox.SetMarginStart(8);
        markdownBox.SetMarginEnd(8);

        ParseMarkdown(markdownBox, release.Markdown);

        card.Append(markdownBox);

        return card;
    }
    

    private static string ProcessInlineMarkdown(string text)
    {
        var escaped = GLib.Markup.EscapeText(text);

        var result = BoldRegex().Replace(escaped, "<b>$1</b>");

        result = UrlRegex().Replace(result, "<a href='$1'>$1</a>");
        
        result = MentionRegex().Replace(result, "<b>$1</b>");

        return result;
    }

    [GeneratedRegex(@"\*\*(.*?)\*\*")]
    private static partial Regex BoldRegex();
    [GeneratedRegex(@"(https?://[^\s]+)")]
    private static partial Regex UrlRegex();
    [GeneratedRegex(@"(@[a-zA-Z0-9_-]+)")]
    private static partial Regex MentionRegex();
}
