using System.Security.Cryptography;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;
using Shelly.Gtk.Windows.Dialog;

namespace Shelly.Gtk.Windows;

public class MetaSearch(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    IConfigService configService,
    ILockoutService lockoutService) : IShellyWindow
{
    private Box _box = null!;
    private ColumnView _columnView = null!;
    private Gio.ListStore _listStore = null!;
    private SingleSelection _selectionModel = null!;
    private Button _installButton = null!;
    private string? _initialQuery;

    private SignalListItemFactory _checkFactory = null!;
    private SignalListItemFactory _nameFactory = null!;
    private SignalListItemFactory _repoFactory = null!;
    private SignalListItemFactory _versionFactory = null!;
    private SignalListItemFactory _descriptionFactory = null!;

    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _repoColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private ColumnViewColumn _descriptionColumn = null!;

    private Dictionary<ListItem, EventHandler> _checkBinding = [];

    public Widget CreateWindow() => CreateWindow(null);

    public Widget CreateWindow(string? initialQuery)
    {
        _initialQuery = initialQuery;
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/MetaSearchWindow.ui"), -1);

        _box = (Box)builder.GetObject("MetaSearchWindow")!;
        _columnView = (ColumnView)builder.GetObject("package_grid")!;
        _installButton = (Button)builder.GetObject("install_button")!;

        _checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        _nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        _repoColumn = (ColumnViewColumn)builder.GetObject("repo_column")!;
        _versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        _descriptionColumn = (ColumnViewColumn)builder.GetObject("description_column")!;

        _listStore = Gio.ListStore.New(MetaPackageGObject.GetGType());
        _selectionModel = SingleSelection.New(_listStore);
        _selectionModel.CanUnselect = true;
        _columnView.SetModel(_selectionModel);

        SetupColumns(_checkColumn, _nameColumn, _repoColumn, _versionColumn, _descriptionColumn);

        ColumnViewHelper.AlignColumnHeader(_columnView, 2, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 3, Align.End);

        _installButton.OnClicked += (_, _) => { _ = InstallSelectedAsync(); };

        if (!string.IsNullOrEmpty(_initialQuery))
        {
            _ = LoadDataAsync();
        }

        _columnView.OnActivate += (_, _) =>
        {
            if (_selectionModel.GetSelectedItem() is MetaPackageGObject pkgObj)
            {
                pkgObj.ToggleSelection();
            }
        };

        return _box;
    }

    private void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn, ColumnViewColumn repoColumn,
        ColumnViewColumn versionColumn, ColumnViewColumn descriptionColumn)
    {
        _checkFactory = SignalListItemFactory.New();
        _checkFactory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var check = new CheckButton { MarginStart = 10, MarginEnd = 10 };
            listItem.SetChild(check);
            check.OnToggled += (s, _) =>
            {
                if (listItem.GetItem() is MetaPackageGObject pkgObj)
                    pkgObj.IsSelected = s.GetActive();
            };
        };
        _checkFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not MetaPackageGObject pkgObj ||
                listItem.GetChild() is not CheckButton check) return;
            check.SetActive(pkgObj.IsSelected);
            pkgObj.OnSelectionToggled += OnExternalToggle;
            _checkBinding[listItem] = OnExternalToggle;
            return;

            void OnExternalToggle(object? s, EventArgs e)
            {
                if (listItem.GetItem() == pkgObj) check.SetActive(pkgObj.IsSelected);
            }
        };
        _checkFactory.OnUnbind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not MetaPackageGObject pkgObj) return;
            if (_checkBinding.Remove(listItem, out var handler)) pkgObj.OnSelectionToggled -= handler;
        };
        checkColumn.SetFactory(_checkFactory);

        _nameFactory = SignalListItemFactory.New();
        _nameFactory.OnSetup += (_, args) =>
            ((ListItem)args.Object).SetChild(new Label { Halign = Align.Start, MarginStart = 6 });
        _nameFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(pkg.Name);
        };
        nameColumn.SetFactory(_nameFactory);

        _repoFactory = SignalListItemFactory.New();
        _repoFactory.OnSetup += (_, args) =>
            ((ListItem)args.Object).SetChild(new Label { Halign = Align.Start, MarginStart = 6 });
        _repoFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(pkg.Repository);
        };
        repoColumn.SetFactory(_repoFactory);

        _versionFactory = SignalListItemFactory.New();
        _versionFactory.OnSetup += (_, args) =>
            ((ListItem)args.Object).SetChild(new Label { Halign = Align.Start, MarginStart = 6 });
        _versionFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(pkg.Version);
        };
        versionColumn.SetFactory(_versionFactory);

        _descriptionFactory = SignalListItemFactory.New();
        _descriptionFactory.OnSetup += (_, args) =>
            ((ListItem)args.Object).SetChild((new Label { Halign = Align.Start, MarginStart = 6 }));
        _descriptionFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(pkg.Description.Substring(0, pkg.Description.Length > 100 ? 100 : pkg.Description.Length));
        };
        descriptionColumn.SetFactory(_descriptionFactory);
    }

    private async Task LoadDataAsync()
    {
        Console.WriteLine(_initialQuery);
        if (string.IsNullOrWhiteSpace(_initialQuery))
        {
            _listStore.RemoveAll();
            return;
        }

        List<Task<List<MetaPackageModel>>> groupList = [];

        var standardTask = Task.Run(async () =>
        {
            var standardInstalled = await privilegedOperationService.GetInstalledPackagesAsync().ContinueWith(x =>
                x.Result.Select(y => new MetaPackageModel(y.Name, y.Name, y.Version, y.Description,
                    PackageType.STANDARD, y.Description, y.Repository, true)).ToList());
            var standardAvailable = await privilegedOperationService.SearchPackagesAsync(_initialQuery)
                .ContinueWith(x =>
                    x.Result.Select(y => new MetaPackageModel(y.Name, y.Name, y.Version, y.Description,
                        PackageType.STANDARD, y.Description, y.Repository,
                        standardInstalled.Any(z => z.Name == y.Name))).ToList());
            return standardAvailable;
        });
        groupList.Add(standardTask);

        Task<List<MetaPackageModel>>? flatpakGroup = null;
        if (configService.LoadConfig().FlatPackEnabled)
        {
            flatpakGroup = Task.Run(async () =>
            {
                var flatPakInstalled = await unprivilegedOperationService.ListFlatpakPackages().ContinueWith(x =>
                    x.Result.Select(y => new MetaPackageModel(y.Id, y.Name, y.Version, y.Description,
                        PackageType.FLATPAK, y.Summary, "Flathub", true)).ToList());
                var flatpakAvailable = await unprivilegedOperationService.SearchFlathubAsync(_initialQuery)
                    .ContinueWith(x =>
                        x.Result.Select(y => new MetaPackageModel(y.Id, y.Name, y.Version, y.Description,
                            PackageType.FLATPAK, y.Description, y.Id,
                            flatPakInstalled.Any(z => z.Name == y.Name))).ToList());

                return flatpakAvailable;
            });
            groupList.Add(flatpakGroup);
        }

        Task<List<MetaPackageModel>>? aurGroup = null;
        if (configService.LoadConfig().AurEnabled)
        {
            aurGroup = Task.Run(async () =>
            {
                var aurInstalled = await privilegedOperationService.GetAurInstalledPackagesAsync()
                    .ContinueWith(x =>
                        x.Result.Select(y => new MetaPackageModel(y.Name, y.Name, y.Version, y.Description ?? "",
                            PackageType.AUR, y.Url ?? "", "AUR", true)).ToList());
                var aurAvailable = await privilegedOperationService.SearchAurPackagesAsync(_initialQuery)
                    .ContinueWith(x => x.Result.Select(y =>
                        new MetaPackageModel(y.Name, y.Name, y.Version, y.Description ?? "", PackageType.AUR,
                            y.Url ?? "", "AUR", aurInstalled.Any(z => z.Name == y.Name))).ToList());
                return aurAvailable;
            });
            groupList.Add(aurGroup);
        }

        List<MetaPackageModel> models = [];
        await foreach (var completedTask in Task.WhenEach(groupList))
        {
            var metaEnumerable = await completedTask;
            if (metaEnumerable.Count != 0)
            {
                models.AddRange(metaEnumerable.ToList());
            }
        }

        GLib.Functions.IdleAdd(0, () =>
        {
            _listStore.RemoveAll();
            foreach (var model in models)
            {
                _listStore.Append(new MetaPackageGObject { Package = model });
            }

            return false;
        });
    }

    private async Task InstallSelectedAsync()
    {
        var selected = new List<MetaPackageModel>();
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is MetaPackageGObject { IsSelected: true, Package: not null } pkgObj)
            {
                selected.Add(pkgObj.Package);
            }
        }

        if (selected.Count == 0) return;

        try
        {
            lockoutService.Show($"Installing...");

            var standard = selected.Where(x => x.PackageType == PackageType.STANDARD).Select(x => x.Name).ToList();
            var aur = selected.Where(x => x.PackageType == PackageType.AUR).Select(x => x.Name).ToList();
            var flatpak = selected.Where(x => x.PackageType == PackageType.FLATPAK).Select(x => x.Id).ToList();

            if (standard.Count > 0) await privilegedOperationService.InstallPackagesAsync(standard);
            if (aur.Count > 0) await privilegedOperationService.InstallAurPackagesAsync(aur);
            if (flatpak.Count > 0)
            {
                foreach (var pkg in flatpak)
                {
                    await unprivilegedOperationService.InstallFlatpakPackage(pkg);
                }
            }
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to install packages: {e.Message}");
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    public void Dispose()
    {
        // Disconnect the model from the view to break circular refs
        _columnView.SetModel(null);

        // Dispose all GObject items BEFORE removing them
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            if (_listStore.GetObject(i) is MetaPackageGObject pkgObj)
            {
                pkgObj.Package = null;
                pkgObj.Dispose();
            }
        }

        _listStore.RemoveAll();

        _selectionModel.Dispose();
        _listStore.Dispose();

        _checkFactory.Dispose();
        _nameFactory.Dispose();
        _repoFactory.Dispose();
        _versionFactory.Dispose();
        _checkColumn.Dispose();
        _nameColumn.Dispose();
        _repoColumn.Dispose();
        _descriptionColumn.Dispose();
        _versionColumn.Dispose();


        _checkBinding.Clear();

        _columnView = null!;
        _box = null!;
        _selectionModel = null!;
        _listStore = null!;
        _installButton = null!;
        _checkFactory = null!;
        _nameFactory = null!;
        _repoFactory = null!;
        _versionFactory = null!;
        _descriptionFactory = null!;

        GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, true, true);
        GC.WaitForPendingFinalizers();
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, true, true);
    }
}