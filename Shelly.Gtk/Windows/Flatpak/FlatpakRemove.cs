using Gtk;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.Windows.Flatpak;

public class FlatpakRemove(IUnprivilegedOperationService unprivilegedOperationService, ILockoutService lockoutService) : IShellyWindow
{
    private ListView? _listView;
    private readonly CancellationTokenSource _cts = new();
    private Gio.ListStore? _listStore;
    private SingleSelection? _selectionModel;
    private List<FlatpakPackageDto> _allPackages = [];
    private string _searchText = string.Empty;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromFile("UiFiles/Flatpak/FlatpakRemoveWindow.ui");
        var box = (Box)builder.GetObject("FlatpakRemoveWindow")!;
        
        _listView = (ListView)builder.GetObject("installed_flatpaks")!;
        var removeButton = (Button)builder.GetObject("remove_button")!;
        var reloadButton = (Button)builder.GetObject("reload_button")!;
        var searchEntry = (SearchEntry)builder.GetObject("search_entry")!;

        _listStore = Gio.ListStore.New(StringObject.GetGType());
        _selectionModel = SingleSelection.New(_listStore);
        _listView.SetModel(_selectionModel);

        var factory = SignalListItemFactory.New();
        factory.OnSetup += OnSetup;
        factory.OnBind += OnBind;
        _listView.SetFactory(factory);

        _listView.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };
        removeButton.OnClicked += (_, _) => { _ = RemoveSelectedAsync(); };
        reloadButton.OnClicked += (_, _) => { _ = LoadDataAsync(); };
        searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchText = searchEntry.GetText();
            ApplyFilter();
        };

        return box;
    }

    private static void OnSetup(SignalListItemFactory sender, SignalListItemFactory.SetupSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        var hbox = Box.New(Orientation.Horizontal, 10);
        hbox.MarginStart = 10;
        hbox.MarginEnd = 10;
        hbox.MarginTop = 5;
        hbox.MarginBottom = 5;

        var icon = Image.New();
        hbox.Append(icon);

        var vbox = Box.New(Orientation.Vertical, 2);
        var nameLabel = Label.New(string.Empty);
        nameLabel.Halign = Align.Start;
        nameLabel.AddCssClass("heading");

        var idLabel = Label.New(string.Empty);
        idLabel.Halign = Align.Start;
        idLabel.AddCssClass("dim-label");

        vbox.Append(nameLabel);
        vbox.Append(idLabel);
        hbox.Append(vbox);

        var versionLabel = Label.New(string.Empty);
        versionLabel.Halign = Align.End;
        versionLabel.Hexpand = true;
        hbox.Append(versionLabel);

        listItem.SetChild(hbox);
    }

    private void OnBind(SignalListItemFactory sender, SignalListItemFactory.BindSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        if (listItem.GetItem() is not StringObject stringObj) return;
        if (listItem.GetChild() is not Box hbox) return;

        var packageId = stringObj.GetString();
        var package = _allPackages.FirstOrDefault(p => p.Id == packageId);
        if (package == null) return;

        var icon = (Image)hbox.GetFirstChild()!;
        var vbox = (Box)icon.GetNextSibling()!;
        var nameLabel = (Label)vbox.GetFirstChild()!;
        var idLabel = (Label)nameLabel.GetNextSibling()!;
        var versionLabel = (Label)vbox.GetNextSibling()!;
        
        if (!string.IsNullOrEmpty(package.IconPath) && File.Exists(package.IconPath))
        {
            icon.SetFromFile(package.IconPath);
            icon.PixelSize = 64;
        }
        else
        {
            icon.SetFromFile($"/var/lib/flatpak/appstream/flathub/x86_64/active/icons/64x64/{package.Id}.png");
        }

        nameLabel.SetText(package.Name);
        idLabel.SetText(package.Id);
        versionLabel.SetText(package.Version);
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
    }

    private async Task LoadDataAsync(CancellationToken ct = default)
    {
        try
        {
            _allPackages = await unprivilegedOperationService.ListFlatpakPackages();
            ct.ThrowIfCancellationRequested();
            
            GLib.Functions.IdleAdd(0, () =>
            {
                ApplyFilter();
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load installed packages: {e.Message}");
        }
    }

    private void ApplyFilter()
    {
        if (_listStore == null) return;
        
        var filtered = string.IsNullOrWhiteSpace(_searchText)
            ? _allPackages
            : _allPackages.Where(p =>
                p.Name.Contains(_searchText, StringComparison.OrdinalIgnoreCase) ||
                p.Id.Contains(_searchText, StringComparison.OrdinalIgnoreCase));

        _listStore.RemoveAll();

        foreach (var package in filtered)
        {
            _listStore.Append(StringObject.New(package.Id));
        }
    }

    private async Task RemoveSelectedAsync()
    {
        var selectedItem = _selectionModel?.GetSelectedItem();
        if (selectedItem is not StringObject stringObj) return;
        
        var packageId = stringObj.GetString();
        try
        {
            lockoutService.Show($"Removing {packageId}...", 0, true);
            var result = await unprivilegedOperationService.RemoveFlatpakPackage(packageId);
            
            if (!result.Success)
            {
                Console.WriteLine($"Failed to remove package {packageId}: {result.Error}");
            }
            else
            {
                await LoadDataAsync();
            }
        }
        finally
        {
            lockoutService.Hide();
        }
    }
}