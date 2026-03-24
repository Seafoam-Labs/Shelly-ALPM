using GObject;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AUR.GObjects;

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.AUR;

public class AurUpdate(
    IPrivilegedOperationService privilegedOperationService,
    ILockoutService lockoutService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService) : IShellyWindow
{
    private Box _box = null!;
    private readonly CancellationTokenSource _cts = new();
    private ColumnView _columnView = null!;
    private SingleSelection _selectionModel = null!;
    private Gio.ListStore _listStore = null!;
    private string _searchText = string.Empty;
    private FilterListModel _filterListModel = null!;
    private CustomFilter _filter = null!;
    private SignalListItemFactory _checkFactory = null!;
    private SignalListItemFactory _nameFactory = null!;
    private SignalListItemFactory _versionFactory = null!;

    private Dictionary<ColumnViewCell, (SignalHandler<CheckButton> OnToggled, EventHandler OnExternalToggle)>
        _checkBinding = [];

    private readonly List<AurUpdateGObject> _packageGObjectRefs = [];
    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private Button _updateButton = null!;
    private Label _noPackagesLabel = null!;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/AUR/UpdateAurWindow.ui"), -1);
        _box = (Box)builder.GetObject("AurUpdateWindow")!;
        _columnView = (ColumnView)builder.GetObject("package_grid")!;
        var searchEntry = (SearchEntry)builder.GetObject("search_entry")!;

        _checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        _checkColumn.Resizable = true;

        _nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        _nameColumn.Resizable = true;

        _versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        _versionColumn.Resizable = true;

        _updateButton = (Button)builder.GetObject("update_button")!;
        _noPackagesLabel = (Label)builder.GetObject("no_packages_label")!;
        _noPackagesLabel.Label_ = "<span size='large'>AUR packages are up to date</span>";
        _noPackagesLabel.Visible = false;
        _updateButton.SetSensitive(false);

        _listStore = Gio.ListStore.New(AurUpdateGObject.GetGType());
        _filter = CustomFilter.New(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _selectionModel.CanUnselect = true;
        _columnView.SetModel(_selectionModel);

        SetupColumns(_checkColumn, _nameColumn, _versionColumn);

        ColumnViewHelper.AlignColumnHeader(_columnView, 1, Align.End);

        _columnView.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };
        _columnView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            if (item is AurUpdateGObject pkgObj)
            {
                pkgObj.ToggleSelection();
            }
        };
        searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchText = searchEntry.GetText();
            ApplyFilter();
        };
        _updateButton.OnClicked += (_, _) => { _ = RemovePackagesAsync(); };

        return _box;
    }

    private bool FilterPackage(GObject.Object obj)
    {
        if (obj is not AurUpdateGObject pkgObj || pkgObj.Package == null)
            return false;

        return string.IsNullOrWhiteSpace(_searchText) ||
               pkgObj.Package.Name.Contains(_searchText, StringComparison.OrdinalIgnoreCase);
    }

    private void ApplyFilter()
    {
        _filter.Changed(FilterChange.Different);
    }

    private void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn, ColumnViewColumn versionColumn)
    {
        _checkFactory = SignalListItemFactory.New();
        _checkFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var check = new CheckButton { MarginStart = 10, MarginEnd = 10 };
            listItem.SetChild(check);
        };

        _checkFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurUpdateGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;

            checkButton.SetActive(pkgObj.IsSelected);
            checkButton.OnToggled += OnToggled;

            pkgObj.OnSelectionToggled += OnExternalToggle;
            _checkBinding[listItem] = (OnToggled, OnExternalToggle);

            return;

            void OnToggled(CheckButton s, EventArgs e)
            {
                pkgObj.IsSelected = s.GetActive();
                _updateButton.SetSensitive(AnySelected());
            }

            void OnExternalToggle(object? s, EventArgs e)
            {
                if (listItem.GetItem() == pkgObj)
                {
                    checkButton.SetActive(pkgObj.IsSelected);
                }
            }
        };

        _checkFactory.OnUnbind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurUpdateGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;
            if (_checkBinding.Remove(listItem, out var handlers))
            {
                pkgObj.OnSelectionToggled -= handlers.OnExternalToggle;
                checkButton.OnToggled -= handlers.OnToggled;
            }
        };

        checkColumn.SetFactory(_checkFactory);

        _nameFactory = SignalListItemFactory.New();
        _nameFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        _nameFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurUpdateGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Name);
            label.Halign = Align.Start;
        };
        nameColumn.SetFactory(_nameFactory);

        _versionFactory = SignalListItemFactory.New();
        _versionFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        _versionFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurUpdateGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Version);
            label.Halign = Align.End;
        };
        versionColumn.SetFactory(_versionFactory);
    }

    private async Task LoadDataAsync(CancellationToken ct = default)
    {
        try
        {
            var packages = await privilegedOperationService.GetAurUpdatePackagesAsync();
            ct.ThrowIfCancellationRequested();
            Console.WriteLine($@"[DEBUG_LOG] {packages.Count} AUR packages for update.");

            GLib.Functions.IdleAdd(0, () =>
            {
                _listStore.RemoveAll();
                _packageGObjectRefs.Clear();
                foreach (var gobject in packages.Select(dto => new AurUpdateGObject()
                         {
                             Package = dto,
                             IsSelected = false
                         }))
                {
                    _packageGObjectRefs.Add(gobject);
                    _listStore.Append(gobject);
                }

                _noPackagesLabel.Visible = packages.Count == 0;

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
            if (item is AurUpdateGObject { IsSelected: true, Package: not null } pkgObj)
            {
                selectedPackages.Add(pkgObj.Package.Name);
            }
        }

        if (selectedPackages.Count != 0)
        {
            if (!configService.LoadConfig().NoConfirm)
            {
                var args = new GenericQuestionEventArgs(
                    "Update Packages?", string.Join("\n", selectedPackages)
                );

                genericQuestionService.RaiseQuestion(args);
                if (!await args.ResponseTask)
                {
                    return;
                }
            }

            try
            {
                lockoutService.Show($"Installing...");

                var packageBuilds = await privilegedOperationService.GetAurPackageBuild(selectedPackages);

                if (packageBuilds.Count != 0)
                {
                    foreach (var pkgbuild in packageBuilds)
                    {
                        if (pkgbuild.PkgBuild == null) continue;

                        var buildArgs = new PackageBuildEventArgs($"Displaying Package Build {pkgbuild.Name}",
                            pkgbuild.PkgBuild);
                        genericQuestionService.RaisePackageBuild(buildArgs);

                        if (!await buildArgs.ResponseTask)
                        {
                            return;
                        }
                    }
                }

                var result = await privilegedOperationService.UpdateAurPackagesAsync(selectedPackages);
                
                if (result.Success)
                    genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(
                        $"Updated {selectedPackages.Count} Package(s)"));
                else
                    Console.WriteLine($"Failed to remove packages: {result.Error}");

                await LoadDataAsync();
            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to remove packages: {e.Message}");
            }
            finally
            {
                lockoutService.Hide();
            }
        }
    }

    private bool AnySelected()
    {
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AurUpdateGObject { IsSelected: true })
                return true;
        }

        return false;
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
        _listStore.RemoveAll();
        _packageGObjectRefs.Clear();
        _checkBinding.Clear();
    }
}