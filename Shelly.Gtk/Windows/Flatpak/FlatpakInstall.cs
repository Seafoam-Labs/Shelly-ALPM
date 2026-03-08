using Gtk;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.Windows.Flatpak;

public class FlatpakInstall(IUnprivilegedOperationService unprivilegedOperationService, ILockoutService lockoutService, IConfigService configService, IGenericQuestionService genericQuestionService) : IShellyWindow
{
    private ListView? _listView;
    private readonly CancellationTokenSource _cts = new();
    private Gio.ListStore? _listStore;
    private SingleSelection? _selectionModel;
    private DropDown? _categoryDropDown;
    private List<FlatpakPackageDto> _allPackages = [];
    private string _searchText = string.Empty;
    private FlatpakCategories _selectedCategory = FlatpakCategories.None;
    private SignalListItemFactory? _factory;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Flatpak/FlatpakInstallWindow.ui"), -1);
        var box = (Box)builder.GetObject("FlatpakInstallWindow")!;
        
        _listView = (ListView)builder.GetObject("list_flatpaks")!;
        var removeButton = (Button)builder.GetObject("install_button")!;
        var reloadButton = (Button)builder.GetObject("reload_button")!;
        var searchEntry = (SearchEntry)builder.GetObject("search_entry")!;
        _categoryDropDown = (DropDown)builder.GetObject("category_dropdown")!;

        var categories = Enum.GetNames<FlatpakCategories>();
        var categoryStore = StringList.New(categories);
        _categoryDropDown.SetModel(categoryStore);

        _listStore = Gio.ListStore.New(StringObject.GetGType());
        _selectionModel = SingleSelection.New(_listStore);
        _listView.SetModel(_selectionModel);

        _factory = SignalListItemFactory.New();
        _factory.OnSetup += OnSetup;
        _factory.OnBind += OnBind;
        _listView.SetFactory(_factory);

        _listView.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };
        removeButton.OnClicked += (_, _) => { _ = InstallSelectedAsync(); };
        reloadButton.OnClicked += (_, _) => { _ = LoadDataAsync(); };
        searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchText = searchEntry.GetText();
            ApplyFilter();
        };

        _categoryDropDown.OnNotify += (_, args) =>
        {
            if (args.Pspec.GetName() != "selected") return;
            _selectedCategory = (FlatpakCategories)_categoryDropDown.GetSelected();
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

        // Disconnect the model from the view to break circular refs
        _listView?.SetModel(null);

        // Dispose all GObject items BEFORE removing them
        if (_listStore != null)
        {
            for (uint i = 0; i < _listStore.GetNItems(); i++)
            {
                _listStore.GetObject(i)?.Dispose();
            }

            _listStore.RemoveAll();
        }

        _selectionModel?.Dispose();
        _listStore?.Dispose();

        _allPackages = null!;

        _factory?.Dispose();
        _factory = null!;

        _listView = null!;
        _listStore = null!;
        _selectionModel = null!;
        _categoryDropDown = null!;

        GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, true, true);
        GC.WaitForPendingFinalizers();
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, true, true);
    }

    private async Task LoadDataAsync(CancellationToken ct = default)
    {
        try
        {
            lockoutService.Show("Loading available Flatpak packages...", 0, false);
            await unprivilegedOperationService.FlatpakSyncRemoteAppstream();
            ct.ThrowIfCancellationRequested();
            _allPackages = await unprivilegedOperationService.ListAppstreamFlatpak();
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
        finally
        {
            lockoutService.Hide();
        }
    }

    private void ApplyFilter()
    {
        if (_listStore == null) return;
        
        var filtered = _allPackages.AsEnumerable();

        if (!string.IsNullOrWhiteSpace(_searchText))
        {
            filtered = filtered.Where(p =>
                p.Name.Contains(_searchText, StringComparison.OrdinalIgnoreCase) ||
                p.Id.Contains(_searchText, StringComparison.OrdinalIgnoreCase));
        }

        if (_selectedCategory != FlatpakCategories.None)
        {
            var categoryName = _selectedCategory.ToString();
            filtered = filtered.Where(p => p.Categories.Contains(categoryName, StringComparer.OrdinalIgnoreCase));
        }

        _listStore.RemoveAll();
        
        foreach (var package in filtered)
        {
            _listStore.Append(StringObject.New(package.Id));
        }
    }

    private async Task InstallSelectedAsync()
    {
        var selectedItem = _selectionModel?.GetSelectedItem();
        if (selectedItem is not StringObject stringObj) return;
        
        var packageId = stringObj.GetString();
        
        if (!configService.LoadConfig().NoConfirm)
        {
            var args = new GenericQuestionEventArgs(
                "Install Package?", packageId
            );

            genericQuestionService.RaiseQuestion(args);
            if (!await args.ResponseTask)
            {
                return;
            }
        }
        
        try
        {
            lockoutService.Show($"Installing {packageId}...");
            var result = await unprivilegedOperationService.InstallFlatpakPackage(packageId);
            
            if (!result.Success)
            {
                Console.WriteLine($"Failed to install package {packageId}: {result.Error}");
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