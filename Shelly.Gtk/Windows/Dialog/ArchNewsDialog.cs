using Gtk;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Windows.Dialog;

public class ArchNewsDialog(IArchNewsService archNewsService, Overlay overlay)
{
    private List<RssModel> _archNewsItems = [];

    public async void OpenArchNewsOverlay()
    {
        try
        {
            if (_archNewsItems.Count == 0)
            {
                await LoadArchNews();
            }

            var container = Box.New(Orientation.Vertical, 10);
            container.SetMarginBottom(10);
            container.SetMarginEnd(10);
            container.SetMarginStart(10);
            container.SetMarginTop(10);

            var titleLabel = Label.New(T("Arch Linux News"));
            titleLabel.AddCssClass("title-1");
            titleLabel.Xalign = 0;
            container.Append(titleLabel);

            var listBox = ListBox.New();
            listBox.SetSelectionMode(SelectionMode.None);
            listBox.AddCssClass("rich-list");

            var scrolledWindow = ScrolledWindow.New();
            scrolledWindow.SetVexpand(true);
            scrolledWindow.HscrollbarPolicy = PolicyType.Never;
            scrolledWindow.SetChild(listBox);
            container.Append(scrolledWindow);

            var args = new GenericDialogEventArgs(container);
            GenericOverlay.ShowGenericOverlay(overlay, container, args, 700, 500);

            if (_archNewsItems.Count == 0)
            {
                var placeholder = Label.New(T("No news available"));
                placeholder.AddCssClass("dim-label");
                placeholder.Halign = Align.Center;
                placeholder.MarginTop = 20;
                listBox.Append(placeholder);
            }
            else
            {
                foreach (var item in _archNewsItems)
                {
                    var row = ListBoxRow.New();
                    var vbox = Box.New(Orientation.Vertical, 5);
                    vbox.MarginStart = 10;
                    vbox.MarginEnd = 10;
                    vbox.MarginTop = 10;
                    vbox.MarginBottom = 10;

                    var newsTitle = Label.New(item.Title);
                    newsTitle.AddCssClass("title-4");
                    newsTitle.Xalign = 0;
                    newsTitle.Wrap = true;
                    vbox.Append(newsTitle);

                    if (!string.IsNullOrEmpty(item.PubDate))
                    {
                        var dateLabel = Label.New(item.PubDate);
                        dateLabel.AddCssClass("caption");
                        dateLabel.AddCssClass("dim-label");
                        dateLabel.Xalign = 0;
                        vbox.Append(dateLabel);
                    }

                    if (!string.IsNullOrEmpty(item.Description))
                    {
                        var descLabel = Label.New(item.Description);
                        descLabel.Xalign = 0;
                        descLabel.Wrap = true;
                        descLabel.Lines = 3;
                        descLabel.Ellipsize = Pango.EllipsizeMode.End;
                        vbox.Append(descLabel);
                    }

                    row.SetChild(vbox);
                    listBox.Append(row);
                }
            }
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load arch news {e}");
        }
    }

    private async Task LoadArchNews()
    {
        try
        {
            var items = await archNewsService.FetchNewsAsync(CancellationToken.None);
            items.Reverse();
            _archNewsItems = items.Take(10).ToList();
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load Arch News: {e.Message}");
        }
    }
}