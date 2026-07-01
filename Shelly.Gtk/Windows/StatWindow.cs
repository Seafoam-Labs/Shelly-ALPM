using Gdk;
using GdkPixbuf;
using Gio;
using GLib;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Utilities;
using static Shelly.GTK.Resources.Translations;
using Functions = GLib.Functions;
using Task = System.Threading.Tasks.Task;

namespace Shelly.Gtk.Windows;

public sealed class StatWindow(
    IConfigService configService,
    IUnprivilegedOperationService unprivilegedOperationService)
    : IShellyWindow
{
    private Box _aurBox = null!;
    private Label _aurPercentLabel = null!;
    private Box _flatpakBox = null!;
    private Label _flatpakPercentLabel = null!;
    private Box _root = null!;
    private Label _standardPercentLabel = null!;

    private Label _totalAurLabel = null!;
    private Label _totalFlatpakLabel = null!;
    private Label _totalPackagesLabel = null!;

    public Widget CreateWindow()
    {
        _root = Box.New(Orientation.Vertical, 10);
        _root.MarginStart = 10;
        _root.MarginEnd = 10;
        _root.MarginTop = 10;

        var title = Label.New(T("Package Statistics"));
        title.AddCssClass("title-2");
        title.SetHalign(Align.Center);
        _root.Append(title);

        var statsRow = Box.New(Orientation.Horizontal, 20);
        statsRow.Homogeneous = true;
        statsRow.MarginTop = 10;

        _aurBox = CreateStatColumn(T("Total Aur"), out _totalAurLabel, out _aurPercentLabel);
        _aurBox.MarginTop = 13;
        statsRow.Append(_aurBox);

        var packagesBox = CreateStatColumn(T("Total Packages"), out _totalPackagesLabel, out _standardPercentLabel);
        statsRow.Append(packagesBox);

        _flatpakBox = CreateStatColumn(T("Total Flatpak"), out _totalFlatpakLabel, out _flatpakPercentLabel);
        _flatpakBox.MarginTop = 13;
        statsRow.Append(_flatpakBox);

        _root.Append(statsRow);

        var image = LoadImageFromResource();
        image.PixelSize = 192;
        image.SetHalign(Align.Center);

        _root.Append(image);

        _root.OnRealize += (_, _) => _ = LoadDataAsync();

        var config = configService.LoadConfig();
        _aurBox.Visible = config.AurEnabled;
        _flatpakBox.Visible = config.FlatPackEnabled;

        configService.ConfigSaved += OnConfigServiceOnConfigSaved;

        return _root;
    }

    public void Dispose()
    {
        configService.ConfigSaved -= OnConfigServiceOnConfigSaved;
        _root.Unparent();
    }

    private static Image LoadImageFromResource()
    {
        using var stream = ResourceHelper.GetResourceStream("Assets/shellychel.png");
        using var ms = new MemoryStream();
        stream.CopyTo(ms);
        var gioStream = MemoryInputStream.NewFromBytes(Bytes.New(ms.ToArray()));
        var pixbuf = Pixbuf.NewFromStream(gioStream, null)!;
        var texture = Texture.NewForPixbuf(pixbuf);
        var image = Image.NewFromPaintable(texture);
        return image;
    }

    private void OnConfigServiceOnConfigSaved(object? _, ShellyConfig updatedConfig)
    {
        Functions.IdleAdd(0, () =>
        {
            _aurBox.Visible = updatedConfig.AurEnabled;
            _flatpakBox.Visible = updatedConfig.FlatPackEnabled;
            return false;
        });
    }

    private static Box CreateStatColumn(string title, out Label totalLabel, out Label percentLabel)
    {
        var box = Box.New(Orientation.Vertical, 0);

        var titleLabel = Label.New(title);
        titleLabel.AddCssClass("caption");
        box.Append(titleLabel);

        totalLabel = Label.New("-");
        totalLabel.AddCssClass("title-1");
        box.Append(totalLabel);

        var statusLabel = Label.New(T("Up to date"));
        box.Append(statusLabel);

        percentLabel = Label.New(T("Calculating"));
        percentLabel.SetJustify(Justification.Center);
        box.Append(percentLabel);

        return box;
    }

    private async Task LoadDataAsync()
    {
        try
        {
            var aurTask = unprivilegedOperationService.GetAurInstalledPackagesAsync();
            var packagesTask = unprivilegedOperationService.GetInstalledPackagesAsync();
            var flatpakTask = unprivilegedOperationService.ListFlatpakPackages();
            var updatesTask = unprivilegedOperationService.CheckForApplicationUpdates();

            await Task.WhenAll(aurTask, packagesTask, flatpakTask, updatesTask);

            var aurPackages = aurTask.Result;
            var packages = packagesTask.Result;
            var flatpakPackages = flatpakTask.Result;
            var updates = updatesTask.Result;

            Functions.IdleAdd(0, () =>
            {
                _totalAurLabel.SetText(aurPackages.Count.ToString());
                _aurPercentLabel.SetText(CalculatePercent(aurPackages.Count, updates.Aur.Count));

                _totalPackagesLabel.SetText(packages.Count.ToString());
                _standardPercentLabel.SetText(CalculatePercent(packages.Count, updates.Packages.Count));

                _totalFlatpakLabel.SetText(flatpakPackages.Count.ToString());
                _flatpakPercentLabel.SetText(CalculatePercent(flatpakPackages.Count, updates.Flatpak.Count));

                return false;
            });
        }
        catch (OperationCanceledException)
        {
            // ignored
        }
        catch (Exception ex)
        {
            Console.WriteLine(T($"Error loading dashboard data: {ex.Message}"));
        }
    }

    private static string CalculatePercent(int total, int outdated)
    {
        if (total == 0) return "N/A";
        var ratio = (double)(total - outdated) / total * 100;
        return $"{ratio:F2} %";
    }
}