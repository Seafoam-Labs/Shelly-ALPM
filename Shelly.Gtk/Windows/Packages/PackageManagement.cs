using GObject;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.Packages;

public class PackageManagement(
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
    private FilterListModel _filterListModel = null!;
    private CustomFilter _filter = null!;
    private string _searchText = string.Empty;

    private Dictionary<ColumnViewCell, (SignalHandler<CheckButton> OnToggled, EventHandler OnExternalToggle)>
        _checkBinding = [];

    private SignalListItemFactory _checkFactory = null!;
    private SignalListItemFactory _nameFactory = null!;
    private SignalListItemFactory _sizeFactory = null!;
    private SignalListItemFactory _versionFactory = null!;
    private SearchEntry _searchEntry = null!;
    private CheckButton _cascadeDeleteCheck = null!;
    private CheckButton _removeConfigsCheck = null!;
    private Button _refreshButton = null!;
    private Button _removeButton = null!;
    private readonly List<AlpmPackageGObject> _packageGObjectRefs = [];
    private List<AlpmPackageDto> _packages = [];
    private List<string> _groups = [];
    private StringList _groupsStringList = null!;
    private DropDown _groupDropDown = null!;
    private string _selectedGroup = "Any";

    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _sizeColumn = null!;
    private ColumnViewColumn _versionColumn = null!;


    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Package/PackageManagement.ui"), -1);
        _box = (Box)builder.GetObject("PackageManagement")!;
        _columnView = (ColumnView)builder.GetObject("package_grid")!;
        _searchEntry = (SearchEntry)builder.GetObject("search_entry")!;
        _cascadeDeleteCheck = (CheckButton)builder.GetObject("cascade_delete_check")!;
        _removeConfigsCheck = (CheckButton)builder.GetObject("remove_configs_check")!;

        _checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        _checkColumn.Resizable = true;
        _nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        _nameColumn.Resizable = true;
        _sizeColumn = (ColumnViewColumn)builder.GetObject("size_column")!;
        _sizeColumn.Resizable = true;
        _versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        _versionColumn.Resizable = true;

        _refreshButton = (Button)builder.GetObject("sync_button")!;
        _removeButton = (Button)builder.GetObject("remove_button")!;
        _removeButton.SetSensitive(false);

        _listStore = Gio.ListStore.New(AlpmPackageGObject.GetGType());
        _filter = CustomFilter.New(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _selectionModel.CanUnselect = true;
        _columnView.SetModel(_selectionModel);
        _groupDropDown = (DropDown)builder.GetObject("grouping_selection")!;


        SetupColumns(_checkColumn, _nameColumn, _sizeColumn, _versionColumn);

        ColumnViewHelper.AlignColumnHeader(_columnView, 1, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 2, Align.End);

        _columnView.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };
        _columnView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            if (item is AlpmPackageGObject pkgObj)
            {
                pkgObj.ToggleSelection();
            }
        };
        _searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchText = _searchEntry.GetText();
            ApplyFilter();
        };
        _removeButton.OnClicked += (_, _) => { _ = RemoveSelectedAsync(); };
        _refreshButton.OnClicked += (_, _) => { _ = LoadDataAsync(); };
        _groupDropDown.OnNotify += (sender, args) =>
        {
            if (args.Pspec.GetName() == "selected")
            {
                var idx = _groupDropDown.GetSelected();
                var item = (StringObject)_groupDropDown.GetModel()!.GetObject(idx)!;
                _selectedGroup = item.GetString();
                ApplyFilter();
            }
        };

        return _box;
    }

    private void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn, ColumnViewColumn sizeColumn,
        ColumnViewColumn versionColumn)
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
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;

            checkButton.SetActive(pkgObj.IsSelected);
            checkButton.OnToggled += OnToggled;

            pkgObj.OnSelectionToggled += OnExternalToggle;
            _checkBinding[listItem] = (OnToggled, OnExternalToggle);

            return;

            void OnToggled(CheckButton s, EventArgs e)
            {
                pkgObj.IsSelected = s.GetActive();
                _removeButton.SetSensitive(AnySelected());
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
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
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
            if (listItem.GetItem() is not AlpmPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Name);
            label.Halign = Align.Start;
        };
        nameColumn.SetFactory(_nameFactory);

        _sizeFactory = SignalListItemFactory.New();
        _sizeFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        _sizeFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(SizeHelpers.FormatSize(pkg.InstalledSize));
            label.Halign = Align.End;
        };
        sizeColumn.SetFactory(_sizeFactory);

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
            if (listItem.GetItem() is not AlpmPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Version);
            label.Halign = Align.End;
        };

        versionColumn.SetFactory(_versionFactory);
    }

    private bool FilterPackage(GObject.Object obj)
    {
        if (obj is AlpmPackageGObject pkgObj && pkgObj.Package != null)
        {
            if (_selectedGroup != "Any" && !pkgObj.Package.Groups.Contains(_selectedGroup))
            {
                return false;
            }

            if (string.IsNullOrWhiteSpace(_searchText))
                return true;

            return pkgObj.Package.Name.Contains(_searchText, StringComparison.OrdinalIgnoreCase) ||
                   pkgObj.Package.Description.Contains(_searchText, StringComparison.OrdinalIgnoreCase);
        }

        return false;
    }

    private async Task LoadDataAsync(CancellationToken ct = default)
    {
        try
        {
            _packages = await privilegedOperationService.GetInstalledPackagesAsync();
            _groups = _packages.SelectMany(x => x.Groups).Distinct().ToList();
            _groups.Insert(0, "Any");
            _groupsStringList = StringList.New(_groups.ToArray());
            _groupDropDown.SetModel(_groupsStringList);
            ct.ThrowIfCancellationRequested();
            GLib.Functions.IdleAdd(0, () =>
            {
                _listStore.RemoveAll();
                _packageGObjectRefs.Clear();
                foreach (var package in _packages)
                {
                    var pkgObj = new AlpmPackageGObject { Package = package };
                    _packageGObjectRefs.Add(pkgObj);
                    _listStore.Append(pkgObj);
                }

                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load packages: {e.Message}");
        }
    }

    private void ApplyFilter()
    {
        _filter.Changed(FilterChange.Different);
    }

    private async Task RemoveSelectedAsync()
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
            if (!configService.LoadConfig().NoConfirm)
            {
                var args = new GenericQuestionEventArgs(
                    "Remove Packages?", string.Join("\n", selectedPackages)
                );

                genericQuestionService.RaiseQuestion(args);
                if (!await args.ResponseTask)
                {
                    return;
                }
            }

            try
            {
                lockoutService.Show($"Removing...");
                await privilegedOperationService.RemovePackagesAsync(selectedPackages, _cascadeDeleteCheck.Active,
                    _removeConfigsCheck.Active);
                await LoadDataAsync();
            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to install packages: {e.Message}");
            }
            finally
            {
                lockoutService.Hide();

                var args = new ToastMessageEventArgs(
                    $"Removed {selectedPackages.Count} Package(s)"
                );

                genericQuestionService.RaiseToastMessage(args);
            }
        }
    }

    private bool AnySelected()
    {
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AlpmPackageGObject { IsSelected: true })
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
        _packages.Clear();
        _groups.Clear();
    }
}