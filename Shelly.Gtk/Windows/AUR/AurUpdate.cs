using GObject;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Enums;
using static Shelly.Gtk.Helpers.AurColumnViewSorter;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AUR.GObjects;
// ReSharper disable NotAccessedField.Local

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.AUR;

public class AurUpdate(
    IPrivilegedOperationService privilegedOperationService,
    ILockoutService lockoutService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService,
    IDirtyService dirtyService) : IShellyWindow, IReloadable
{
    private DirtySubscription? _sub;
    public string[] ListensTo => [DirtyScopes.AurUpdates, DirtyScopes.AurInstalled];
    private Box _box = null!;
    private CancellationTokenSource _cts = new();
    private int _loadGeneration;
    private ColumnView _columnView = null!;
    private SingleSelection _selectionModel = null!;
    private Gio.ListStore _listStore = null!;
    private string _searchText = string.Empty;
    private FilterListModel _filterListModel = null!;
    private CustomFilter _filter = null!;
    private SignalListItemFactory _checkFactory = null!;
    private SignalListItemFactory _nameFactory = null!;
    private SignalListItemFactory _versionFactory = null!;
    private ColumnViewSorter _columnViewSorter = null!;
    private Box _detailBox = null!;
    private AurUpdateGObject? _currentDetailPkg;
    private Revealer _detailRevealer = null!;

    private Dictionary<ColumnViewCell, (SignalHandler<CheckButton> OnToggled, EventHandler OnExternalToggle)>
        _checkBinding = [];

    private readonly List<AurUpdateGObject> _packageGObjectRefs = [];
    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private Button _updateButton = null!;
    private Label _noPackagesLabel = null!;
    private CheckButton _showHiddenCheck = null!;
    private CheckButton _runChecksCheck = null!;

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

        _detailBox = (Box)builder.GetObject("detail_box")!;
        _detailRevealer = (Revealer)builder.GetObject("detail_revealer")!;

        _updateButton = (Button)builder.GetObject("update_button")!;
        _runChecksCheck = (CheckButton)builder.GetObject("run_checks_check")!;
        _showHiddenCheck = (CheckButton)builder.GetObject("show_hidden_check")!;
        _noPackagesLabel = (Label)builder.GetObject("no_packages_label")!;
        _noPackagesLabel.Label_ = "<span size='large'>AUR packages are up to date</span>";
        _noPackagesLabel.Visible = false;
        _updateButton.SetSensitive(false);

        _listStore = Gio.ListStore.New(AurUpdateGObject.GetGType());
        _filter = PackageSearch.CreateSafeFilter(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _selectionModel.CanUnselect = true;
        _selectionModel.Autoselect = true;
        _columnView.SetModel(_selectionModel);

        SetupColumns(_checkColumn, _nameColumn, _versionColumn);
        
        // Creating sorter
        _nameColumn.Sorter = CustomSorter.New<AurPackageGObject>((a, b) => 0);
        _versionColumn.Sorter = CustomSorter.New<AurPackageGObject>((a, b) => 0);
        
        _columnViewSorter = (ColumnViewSorter)_columnView.GetSorter()!;

        _columnViewSorter.OnChanged += (_, _) =>
        {
            var primaryColumn =
                _columnViewSorter.GetPrimarySortColumn();
            
            if (primaryColumn is null)
                return;
            
            var sortColumn = GetSortColumn(primaryColumn);
            
            var order =
                _columnViewSorter.GetPrimarySortOrder();
            
            if (sortColumn is null)
                return;

            Sort(
                _listStore,
                _packageGObjectRefs,
                sortColumn.Value,
                order
            );
        };        


        ColumnViewHelper.AlignColumnHeader(_columnView, 1, Align.Start);
        ColumnViewHelper.AlignColumnHeader(_columnView, 2, Align.End);

        
        _columnView.OnRealize += (_, _) => { Reload(); };
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
        _showHiddenCheck.OnToggled += (_, _) => { Reload(); };
        _sub = DirtySubscription.Attach(dirtyService, this);

        _selectionModel.OnSelectionChanged += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            _detailRevealer.SetTransitionType(RevealerTransitionType.SlideLeft);
            if (item is AurUpdateGObject pkgObj)
            {
                ShowPackageDetails(pkgObj);
            }
            else
            {
                _detailRevealer.SetTransitionType(RevealerTransitionType.SlideLeft);
                _detailRevealer.SetRevealChild(false);
                _currentDetailPkg = null;
            }
        };

        return _box;
    }
    
    private PackageSortColumn? GetSortColumn(ColumnViewColumn column)
    {
        if (column == _nameColumn)
            return PackageSortColumn.Name;
        
        if (column == _versionColumn)
            return PackageSortColumn.Version;

        return null;
    }


    private bool FilterPackage(GObject.Object obj)
    {
        if (obj is not AurUpdateGObject { Package: { } pkg })
            return false;

        return PackageSearch.MatchesName(pkg.Name, _searchText);
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
            var check = CheckButton.New();
            check.MarginStart = 10;
            check.MarginEnd = 10;
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

    private async Task LoadDataAsync(CancellationToken ct = default, int generation = 0)
    {
        try
        {
            var packages = await privilegedOperationService.GetAurUpdatePackagesAsync(_showHiddenCheck.Active);
            ct.ThrowIfCancellationRequested();
            Console.WriteLine($@"[DEBUG_LOG] {packages.Count} AUR packages for update.");

            GLib.Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested || _loadGeneration != generation) return false;

                _filterListModel.SetFilter(null);
                _listStore.RemoveAll();
                foreach (var r in _packageGObjectRefs) r.Dispose();
                _packageGObjectRefs.Clear();
                _filterListModel.SetFilter(_filter);
                _detailRevealer.SetRevealChild(false);
                _currentDetailPkg = null;

                foreach (var gobject in packages.Select(dto =>
                         {
                             var o = AurUpdateGObject.NewWithProperties([]);
                             o.Package = dto;
                             o.IsSelected = false;
                             return o;
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

                var result =
                    await privilegedOperationService.UpdateAurPackagesAsync(selectedPackages,
                        _runChecksCheck.GetActive());

                if (result.Success)
                    genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(
                        $"Updated {selectedPackages.Count} Package(s)"));
                else
                    Console.WriteLine($"Failed to remove packages: {result.Error}");

                Reload();
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

    private void ShowPackageDetails(AurUpdateGObject pkgObj)
    {
        if (pkgObj.Package == null) return;

        _currentDetailPkg = pkgObj;
        var pkg = pkgObj.Package;

        while (_detailBox.GetFirstChild() is { } child)
        {
            _detailBox.Remove(child);
        }

        var backButton = Button.New();
        backButton.SetIconName("go-next-symbolic");
        backButton.Halign = Align.Start;
        backButton.AddCssClass("flat");
        backButton.TooltipText = "Close details";
        backButton.OnClicked += (_, _) =>
        {
            _currentDetailPkg = null;
            _selectionModel.UnselectItem(_selectionModel.GetSelected());
            _detailRevealer.SetTransitionType(RevealerTransitionType.SlideLeft);
            _detailRevealer.SetRevealChild(false);
        };
        _detailBox.Append(backButton);

        void AddDetail(string label, string value)
        {
            var row = Box.New(Orientation.Horizontal, 12);
            row.MarginBottom = 4;
            var labelWidget = Label.New(label + ":");
            labelWidget.AddCssClass("dim-label");
            labelWidget.Halign = Align.Start;
            labelWidget.Valign = Align.Start;
            labelWidget.WidthRequest = 80;
            labelWidget.Xalign = 0;

            var valueWidget = Label.New(value);
            valueWidget.Halign = Align.Start;
            valueWidget.Wrap = true;
            valueWidget.WrapMode = Pango.WrapMode.WordChar;
            valueWidget.MaxWidthChars = 30;
            valueWidget.Xalign = 0;
            valueWidget.Selectable = true;

            row.Append(labelWidget);
            row.Append(valueWidget);
            _detailBox.Append(row);
        }

        var headerBox = Box.New(Orientation.Vertical, 4);
        headerBox.MarginBottom = 16;
        headerBox.MarginTop = 8;

        var iconImage = Image.New();
        iconImage.PixelSize = 64;
        iconImage.Halign = Align.Center;
        iconImage.MarginBottom = 8;
        
        iconImage.SetFromIconName("package-x-generic");

        headerBox.Append(iconImage);

        var nameLabel = Label.New(pkg.Name);
        nameLabel.AddCssClass("title-2");
        nameLabel.Halign = Align.Center;
        headerBox.Append(nameLabel);

        var descLabel = Label.New(pkg.Description);
        descLabel.AddCssClass("dim-label");
        descLabel.Halign = Align.Center;
        descLabel.Wrap = true;
        descLabel.Justify = Justification.Center;
        descLabel.MaxWidthChars = 40;
        headerBox.Append(descLabel);

        _detailBox.Append(headerBox);

        var separator = Separator.New(Orientation.Horizontal);
        separator.MarginBottom = 16;
        _detailBox.Append(separator);

        AddDetail("Version", pkg.Version);

        if (!string.IsNullOrEmpty(pkg.Url))
        {
            var row = Box.New(Orientation.Horizontal, 12);
            row.MarginBottom = 4;
            var labelWidget = Label.New("URL:");
            labelWidget.AddCssClass("dim-label");
            labelWidget.Halign = Align.Start;
            labelWidget.Valign = Align.Start;
            labelWidget.WidthRequest = 80;
            labelWidget.Xalign = 0;

            var valueWidget = Label.New(null);
            var escaped = GLib.Functions.MarkupEscapeText(pkg.Url, -1);
            valueWidget.SetMarkup($"<a href=\"{escaped}\">{escaped}</a>");
            valueWidget.Halign = Align.Start;
            valueWidget.Wrap = true;
            valueWidget.WrapMode = Pango.WrapMode.WordChar;
            valueWidget.MaxWidthChars = 30;
            valueWidget.Xalign = 0;

            row.Append(labelWidget);
            row.Append(valueWidget);
            _detailBox.Append(row);
        }

        _detailRevealer.SetRevealChild(true);
    }

    public void Reload()
    {
        var old = Interlocked.Exchange(ref _cts, new CancellationTokenSource());
        old.Cancel();
        old.Dispose();
        Interlocked.Increment(ref _loadGeneration);
        _ = LoadDataAsync(_cts.Token, _loadGeneration);
    }

    public void Dispose()
    {
        _sub?.Dispose();
        _cts.Cancel();
        _cts.Dispose();
        _listStore.RemoveAll();
        foreach (var r in _packageGObjectRefs) r.Dispose();
        _packageGObjectRefs.Clear();
        _checkBinding.Clear();
    }
}