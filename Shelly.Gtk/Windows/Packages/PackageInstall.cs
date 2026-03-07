using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

namespace Shelly.Gtk.Windows.Packages;

public class PackageInstall(IPrivilegedOperationService privilegedOperationService, ILockoutService lockoutService) : IShellyWindow
{
    private Overlay _overlay = null!;
    private readonly CancellationTokenSource _cts = new();
    private ColumnView _columnView = null!;
    private SingleSelection _selectionModel = null!;
    private Gio.ListStore _listStore = null!;
    private FilterListModel _filterListModel = null!;
    private CustomFilter _filter = null!;
    private string _searchText = string.Empty;
    private List<AlpmPackageDto> _packages = [];

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromFile("UiFiles/Package/PackageWindow.ui");
        _overlay = (Overlay)builder.GetObject("PackageWindow")!;
        _columnView = (ColumnView)builder.GetObject("package_column_view")!;
        var checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        var nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        var sizeColumn = (ColumnViewColumn)builder.GetObject("size_column")!;
        var versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        var repositoryColumn = (ColumnViewColumn)builder.GetObject("repository_column")!;
        var installButton = (Button)builder.GetObject("install_button")!;
        var searchEntry = (SearchEntry)builder.GetObject("search_entry")!;
        _listStore = Gio.ListStore.New(AlpmPackageGObject.GetGType());
        _filter = CustomFilter.New(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _selectionModel.CanUnselect = true;
        _columnView.SetModel(_selectionModel);
        SetupColumns(checkColumn, nameColumn, sizeColumn, versionColumn, repositoryColumn);

        _columnView.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };
        _columnView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            if (item is AlpmPackageGObject pkgObj)
            {
                pkgObj.ToggleSelection();
            }
        };
        searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchText = searchEntry.GetText();
            ApplyFilter();
        };
        installButton.OnClicked += (_, _) => { _ = InstallSelectedAsync(); };

        return _overlay;
    }

    private static void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn,
        ColumnViewColumn sizeColumn, ColumnViewColumn versionColumn, ColumnViewColumn repositoryColumn)
    {
        var checkFactory = SignalListItemFactory.New();
        checkFactory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var check = new CheckButton { MarginStart = 10, MarginEnd = 10 };
            listItem.SetChild(check);

            check.OnToggled += (s, _) =>
            {
                if (listItem.GetItem() is AlpmPackageGObject pkgObj)
                {
                    pkgObj.IsSelected = s.GetActive();
                }
            };
        };

        checkFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
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

        checkFactory.OnUnbind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is AlpmPackageGObject pkgObj)
            {
                //if (listItem.GetData<EventHandler>("toggle-handler") is { } handler)
                    //pkgObj.OnSelectionToggled -= handler;
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
            if (listItem.GetItem() is not AlpmPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Name);
            label.Halign = Align.Start;
        };
        nameColumn.SetFactory(nameFactory);

        var sizeFactory = SignalListItemFactory.New();
        sizeFactory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        sizeFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not AlpmPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(SizeHelpers.FormatSize(pkg.InstalledSize));
            label.Halign = Align.End;
        };
        sizeColumn.SetFactory(sizeFactory);

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
            if (listItem.GetItem() is not AlpmPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Version);
            label.Halign = Align.End;
        };
        versionColumn.SetFactory(versionFactory);

        var repositoryFactory = new SignalListItemFactory();
        repositoryFactory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };

        repositoryFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not AlpmPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Repository);
            label.Halign = Align.End;
        };
    }

    public void Dispose()
    {
        _listStore.RemoveAll();
        _cts.Cancel();
        _cts.Dispose();
        _packages.Clear();
    }

    private async Task LoadDataAsync(CancellationToken ct = default)
    {
        try
        {
            _packages = await privilegedOperationService.GetAvailablePackagesAsync();
            ct.ThrowIfCancellationRequested();
            var queue = new Queue<AlpmPackageDto>(_packages);

            GLib.Functions.IdleAdd(0, () =>
            {
                _listStore.RemoveAll();
                return false;
            });

            GLib.Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested)
                {
                    return false;
                }

                // This number might need to be adjusted based on cpu. This comment is just so we can find this later
                // when we inevitably get a bug report about the package page being slow.
                const int batchSize = 1000;
                var count = 0;
                var batch = new List<AlpmPackageGObject>();
                while (queue.Count > 0 && count < batchSize)
                {
                    batch.Add(new AlpmPackageGObject() { Package = queue.Dequeue() });
                    count++;
                }

                // ReSharper disable once CoVariantArrayConversion
                _listStore.Splice(_listStore.GetNItems(), 0, batch.ToArray(), (uint)batch.Count);

                return queue.Count > 0;
            });
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load packages: {e.Message}");
        }
    }

    private void ApplyFilter()
    {
        _filter.Changed(FilterChange.Different);
    }

    private bool FilterPackage(GObject.Object obj)
    {
        if (obj is not AlpmPackageGObject pkgObj || pkgObj.Package == null)
            return false;

        if (string.IsNullOrWhiteSpace(_searchText))
            return true;

        return pkgObj.Package.Name.Contains(_searchText, StringComparison.OrdinalIgnoreCase) ||
               pkgObj.Package.Description.Contains(_searchText, StringComparison.OrdinalIgnoreCase);
    }

    private async Task InstallSelectedAsync()
    {
        var selectedPackages = new List<string>();
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AlpmPackageGObject { IsSelected: true, Package: not null } pkgObj)
            {
                selectedPackages.Add(pkgObj.Package.Name);
            }
        }

        if (selectedPackages.Count != 0)
        {
            try
            {
                lockoutService.Show($"Installing...");
                await privilegedOperationService.InstallPackagesAsync(selectedPackages);
                await LoadDataAsync();
            }
            catch (Exception e)
            {
                //this needs to log to a toast message
            }
            finally
            {
                lockoutService.Hide();
            }
        }
    }
}