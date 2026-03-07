using Gtk;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels.AUR.GObjects;

namespace Shelly.Gtk.Windows.AUR;

public class AurRemove(IPrivilegedOperationService privilegedOperationService, ILockoutService lockoutService)
    : IShellyWindow
{
    private Box _box = null!;
    private readonly CancellationTokenSource _cts = new();
    private ColumnView _columnView = null!;
    private SingleSelection _selectionModel = null!;
    private Gio.ListStore _listStore = null!;
    private string _searchText = string.Empty;
    private FilterListModel _filterListModel = null!;
    private CustomFilter _filter = null!;
   

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromFile("UiFiles/AUR/RemoveAurWindow.ui");
        _box = (Box)builder.GetObject("RemoveAurWindow")!;
        _columnView = (ColumnView)builder.GetObject("package_grid")!;
        var searchEntry = (SearchEntry)builder.GetObject("search_entry")!;

        var checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        var nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        var versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        var removeButton = (Button)builder.GetObject("remove_button")!;

        _listStore = Gio.ListStore.New(AurPackageGObject.GetGType());
        _filter = CustomFilter.New(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _selectionModel.CanUnselect = true;
        _columnView.SetModel(_selectionModel);

        SetupColumns(checkColumn, nameColumn, versionColumn);

        _columnView.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };
        _columnView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            if (item is AurPackageGObject pkgObj)
            {
                pkgObj.ToggleSelection();
            }
        };
        searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchText = searchEntry.GetText();
            ApplyFilter();
        };
        removeButton.OnClicked += (_, _) => { _ = RemovePackagesAsync(); };
        
        return _box;
    }

    private bool FilterPackage(GObject.Object obj)
    {
        if (obj is not AurPackageGObject pkgObj || pkgObj.Package == null)
            return false;

        return string.IsNullOrWhiteSpace(_searchText) || pkgObj.Package.Name.Contains(_searchText, StringComparison.OrdinalIgnoreCase);
    }
    
    private void ApplyFilter()
    {
        _filter.Changed(FilterChange.Different);
    }
    
    private static void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn, ColumnViewColumn versionColumn)
    {
        var checkFactory = SignalListItemFactory.New();
        checkFactory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var check = new CheckButton { MarginStart = 10, MarginEnd = 10 };
            listItem.SetChild(check);
            
            check.OnToggled += (s, _) =>
            {
                if (listItem.GetItem() is AurPackageGObject pkgObj)
                {
                    pkgObj.IsSelected = s.GetActive();
                }
            };
        };

        checkFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not AurPackageGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;

            checkButton.SetActive(pkgObj.IsSelected);

            pkgObj.OnSelectionToggled += OnExternalToggle;
            return;

            void OnExternalToggle(object? s, EventArgs e)
            {
                if (listItem.GetItem() == pkgObj)
                {
                    checkButton.SetActive(pkgObj.IsSelected);
                }
            }
        };

        checkColumn.SetFactory(checkFactory);
        
        var nameFactory = SignalListItemFactory.New();
        nameFactory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        nameFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not AurPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Name);
            label.Halign = Align.Start;
        };
        nameColumn.SetFactory(nameFactory);
        
        var versionFactory = SignalListItemFactory.New();
        versionFactory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        versionFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not AurPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Version);
            label.Halign = Align.End;
        };
        versionColumn.SetFactory(versionFactory);
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
            var packages = await privilegedOperationService.GetAurInstalledPackagesAsync();
            ct.ThrowIfCancellationRequested();
            Console.WriteLine($@"[DEBUG_LOG] Loaded {packages.Count} installed packages");

            GLib.Functions.IdleAdd(0, () =>
            {
                _listStore.RemoveAll();
                foreach (var gobject in packages.Select(dto => new AurPackageGObject
                         {
                             Package = dto,
                             IsSelected = false
                         }))
                {
                    _listStore.Append(gobject);
                }

                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine($@"Failed to load installed packages for removal: {e.Message}");
        }
    }

    private async Task RemovePackagesAsync()
    {
        var selectedPackages = new List<string>();
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AurPackageGObject { IsSelected: true, Package: not null } pkgObj)
            {
                selectedPackages.Add(pkgObj.Package.Name);
            }
        }

        if (selectedPackages.Count != 0)
        {
            try
            {
                lockoutService.Show($"Installing...");

                try
                {
                    //do work
                    var result = await privilegedOperationService.RemoveAurPackagesAsync(selectedPackages);
                    if (!result.Success)
                    {
                        Console.WriteLine($"Failed to remove packages: {result.Error}");
                    }

                    await LoadDataAsync();
                }
                finally
                {
                    lockoutService.Hide();
                }
            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to remove packages: {e.Message}");
            }
        }
    }
}