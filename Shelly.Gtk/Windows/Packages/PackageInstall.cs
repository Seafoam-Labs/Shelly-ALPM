using System.Runtime.CompilerServices;
using Gtk;
using Shelly.Gtk.DataStores;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using static Shelly.Gtk.Helpers.PackageColumnViewSorter;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.Icons;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;
using Shelly.Gtk.Windows.Dialog;
using Shelly.Utilities;

// ReSharper disable NotAccessedField.Local

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.Packages;

public class PackageInstall(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    ILockoutService lockoutService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService,
    IIconResolverService iconResolverService,
    IDirtyService dirtyService)
    : IShellyWindow, IReloadable
{
    private DirtySubscription? _sub;
    public string[] ListensTo => [DirtyScopes.NativeInstalled];
    private Overlay _overlay = null!;
    private CancellationTokenSource _cts = new();
    private int _loadGeneration;
    private ColumnView _columnView = null!;
    private SingleSelection _selectionModel = null!;
    private Gio.ListStore _listStore = null!;
    private FilterListModel _filterListModel = null!;
    private CustomFilter _filter = null!;
    private string _searchText = string.Empty;
    private List<string> _groups = [];
    private StringList _groupsStringList = null!;
    private string _selectedGroup = "Any";

    private SignalListItemFactory _checkFactory = null!;
    private SignalListItemFactory _nameFactory = null!;
    private SignalListItemFactory _sizeFactory = null!;
    private SignalListItemFactory _versionFactory = null!;
    private SignalListItemFactory _repositoryFactory = null!;
    private readonly List<AlpmPackageGObject> _packageGObjectRefs = [];
    private readonly List<AlpmPackageDto> _packageData = [];

    private Button _installButton = null!;
    private Button _localInstallButton = null!;
    private SearchEntry _searchEntry = null!;
    private Builder _builder = null!;
    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _sizeColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private ColumnViewColumn _repositoryColumn = null!;
    private ColumnViewSorter _columnViewSorter = null!;
    private DropDown _groupDropDown = null!;
    private CheckButton _upgradeCheck = null!;
    private CheckButton _showHiddenCheck = null!;

    private Revealer _detailRevealer = null!;
    private Box _detailBox = null!;
    private AlpmPackageGObject? _currentDetailPkg;
    private HashSet<string> _installedPackageNames = [];
    private static readonly ConditionalWeakTable<CheckButton, BindState> _checkState = new();

    public Widget CreateWindow()
    {
        _builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Package/PackageWindow.ui"), -1);
        _overlay = (Overlay)_builder.GetObject("PackageWindow")!;
        _columnView = (ColumnView)_builder.GetObject("package_column_view")!;
        _checkColumn = (ColumnViewColumn)_builder.GetObject("check_column")!;
        _checkColumn.Resizable = true;
        _nameColumn = (ColumnViewColumn)_builder.GetObject("name_column")!;
        _nameColumn.Resizable = true;
        _sizeColumn = (ColumnViewColumn)_builder.GetObject("size_column")!;
        _sizeColumn.Resizable = true;
        _versionColumn = (ColumnViewColumn)_builder.GetObject("version_column")!;
        _versionColumn.Resizable = true;
        _repositoryColumn = (ColumnViewColumn)_builder.GetObject("repository_column")!;
        _repositoryColumn.Resizable = true;
        _installButton = (Button)_builder.GetObject("install_button")!;
        _installButton.SetSensitive(false);
        _localInstallButton = (Button)_builder.GetObject("install_local_button")!;
        _searchEntry = (SearchEntry)_builder.GetObject("search_entry")!;
        _detailRevealer = (Revealer)_builder.GetObject("detail_revealer")!;
        _detailBox = (Box)_builder.GetObject("detail_box")!;
        _groupDropDown = (DropDown)_builder.GetObject("grouping_selection")!;
        _upgradeCheck = (CheckButton)_builder.GetObject("upgrade_check")!;
        _showHiddenCheck = (CheckButton)_builder.GetObject("show_hidden_check")!;

        _listStore = Gio.ListStore.New(AlpmPackageGObject.GetGType());
        _filter = PackageSearch.CreateSafeFilter(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _selectionModel.CanUnselect = true;
        _selectionModel.Autoselect = true;
        _columnView.SetModel(_selectionModel);

        SetupColumns(_checkColumn, _nameColumn, _sizeColumn, _versionColumn, _repositoryColumn);

        // Creating sorter
        _nameColumn.Sorter = CustomSorter.New<AlpmPackageGObject>((a, b) => 0);
        _repositoryColumn.Sorter = CustomSorter.New<AlpmPackageGObject>((a, b) => 0);
        _versionColumn.Sorter = CustomSorter.New<AlpmPackageGObject>((a, b) => 0);

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
                _packageData,
                _packageGObjectRefs,
                sortColumn.Value,
                order
            );
        };

        ColumnViewHelper.AlignColumnHeader(_columnView, 1, Align.Start);
        ColumnViewHelper.AlignColumnHeader(_columnView, 2, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 3, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 4, Align.End);

        _columnView.OnRealize += (_, _) => { Reload(); };
        _columnView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            if (item is AlpmPackageGObject pkgObj)
            {
                pkgObj.ToggleSelection();
            }
        };
        _selectionModel.OnSelectionChanged += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            _detailRevealer.SetTransitionType(RevealerTransitionType.SlideLeft);
            if (item is AlpmPackageGObject pkgObj)
            {
                ShowPackageDetails(pkgObj);
            }
            else
            {
                _detailRevealer.SetRevealChild(false);
                _currentDetailPkg = null;
            }
        };
        _searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchText = _searchEntry.GetText();
            ApplyFilter();
        };
        _installButton.OnClicked += (_, _) => { _ = InstallSelectedAsync(); };
        _installButton.CanFocus = true;
        _installButton.ReceivesDefault = true;

        var shortcutController = ShortcutController.New();
        shortcutController.Scope = ShortcutScope.Global;
        shortcutController.PropagationPhase = PropagationPhase.Capture;

        var triggers = new[] { "Return", "KP_Enter", "space", "<Control>f"};
        foreach (var triggerStr in triggers)
        {
            var action = CallbackAction.New((_, _) =>
            {
                if (triggerStr == "<Control>f")
                {
                    _searchEntry.GrabFocus();
                    return true;
                }
                
                if (!_installButton.GetSensitive()) return false;
                if (OverlayHelper.HasActiveOverlay(_overlay)) return false;

                Task.Run(async () => await InstallSelectedAsync());
                return true;
            });
            shortcutController.AddShortcut(Shortcut.New(ShortcutTrigger.ParseString(triggerStr), action));
        }

        _overlay.AddController(shortcutController);

        _localInstallButton.OnClicked += (_, _) => { _ = InstallLocalPackage(); };
        _showHiddenCheck.OnToggled += (_, _) => { Reload(); };

        _groupDropDown.OnNotify += (_, args) =>
        {
            if (args.Pspec.GetName() == "selected")
            {
                var idx = _groupDropDown.GetSelected();
                if (idx != uint.MaxValue && _groupDropDown.GetModel()?.GetObject(idx) is StringObject item)
                {
                    _selectedGroup = item.GetString();
                    ApplyFilter();
                }
            }
        };
        _sub = DirtySubscription.Attach(dirtyService, this);
        return _overlay;
    }

    private PackageSortColumn? GetSortColumn(ColumnViewColumn column)
    {
        if (column == _nameColumn)
            return PackageSortColumn.Name;

        if (column == _repositoryColumn)
            return PackageSortColumn.Repo;

        if (column == _versionColumn)
            return PackageSortColumn.Version;

        return null;
    }

    public void Reload()
    {
        var old = Interlocked.Exchange(ref _cts, new CancellationTokenSource());
        old.Cancel();
        old.Dispose();
        Interlocked.Increment(ref _loadGeneration);
        _ = LoadDataAsync(_cts.Token, _loadGeneration);
    }

    private void ShowPackageDetails(AlpmPackageGObject pkgObj)
    {
        if (pkgObj.Index < 0 || pkgObj.Index >= _packageData.Count) return;

        _currentDetailPkg = pkgObj;
        var pkg = _packageData[pkgObj.Index];

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

        var iconPath = iconResolverService.GetIconPath(pkg.Name);
        if (!string.IsNullOrEmpty(iconPath) && iconPath != "Unavailable" && File.Exists(iconPath))
        {
            iconImage.SetFromFile(iconPath);
        }
        else
        {
            iconImage.SetFromIconName("package-x-generic");
        }

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
        AddDetail("Repository", pkg.Repository);
        AddDetail("Size", SizeHelper.FormatSize(pkg.InstalledSize));
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

        if (pkg.Depends.Count > 0)
        {
            AddChipList("Depends", pkg.Depends);
        }

        if (pkg.OptDepends.Count > 0)
        {
            AddChipList("Optional Deps", pkg.OptDepends, true);
        }

        if (pkg.Licenses.Count > 0)
            AddDetail("Licenses", string.Join(", ", pkg.Licenses));
        if (pkg.Provides.Count > 0)
            AddDetail("Provides", string.Join(", ", pkg.Provides));
        if (pkg.Conflicts.Count > 0)
            AddDetail("Conflicts", string.Join(", ", pkg.Conflicts));
        if (pkg.Groups.Count > 0)
            AddDetail("Groups", string.Join(", ", pkg.Groups));

        if (configService.LoadConfig().WebViewEnabled)
        {
            if (pkg.Depends.Count > 0)
            {
                var dictionary = new Dictionary<string, List<string>> { { pkg.Name, pkg.Depends } };

                foreach (var dep in pkg.Depends)
                {
                    for (uint i = 0; i < _listStore.GetNItems(); i++)
                    {
                        var obj = _listStore.GetObject(i);
                        if (obj is not AlpmPackageGObject depObj) continue;
                        if (depObj.Index < 0 || depObj.Index >= _packageData.Count) continue;
                        var depPkg = _packageData[depObj.Index];
                        if (depPkg.Name.Contains(dep))
                            dictionary.TryAdd(depPkg.Name, depPkg.Depends);
                    }
                }

                var window = new WebWindow(pkg.Name, dictionary);
                _detailBox.Append(window.CreateWindow());
            }
        }

        _detailRevealer.SetRevealChild(true);
        return;

        void AddChipList(string label, IReadOnlyList<string> items, bool isOptional = false)
        {
            var expander = Expander.New($"{label} ({items.Count})");
            expander.AddCssClass("package-detail-expander");
            expander.Hexpand = false;

            var flowBox = FlowBox.New();
            flowBox.SelectionMode = SelectionMode.None;
            flowBox.ColumnSpacing = 6;
            flowBox.RowSpacing = 6;
            flowBox.Halign = Align.Start;
            flowBox.Valign = Align.Start;
            flowBox.MaxChildrenPerLine = isOptional ? 1u : 10u;
            flowBox.MinChildrenPerLine = 1;

            foreach (var item in items)
            {
                if (isOptional)
                {
                    var optDepName = item.Split(':').First().Trim();
                    var isInstalled = _installedPackageNames.Contains(optDepName);

                    var escapedItem = GLib.Functions.MarkupEscapeText(item, -1);

                    var chipBox = Box.New(Orientation.Horizontal, 4);
                    chipBox.AddCssClass("package-chip");
                    chipBox.Valign = Align.Center;

                    var checkIcon = Image.NewFromIconName("object-select-symbolic");
                    checkIcon.PixelSize = 16;
                    checkIcon.Visible = isInstalled;

                    var chipLabel = Label.New(string.Empty);
                    chipLabel.SetMarkup($"<span size='small'>{escapedItem}</span>");
                    chipLabel.Selectable = true;
                    chipLabel.Ellipsize = Pango.EllipsizeMode.End;
                    chipLabel.MaxWidthChars = 25;
                    chipLabel.Wrap = true;
                    chipLabel.WrapMode = Pango.WrapMode.WordChar;
                    chipLabel.Xalign = 0;

                    chipBox.Append(checkIcon);
                    chipBox.Append(chipLabel);
                    flowBox.Append(chipBox);
                }
                else
                {
                    var chip = Label.New(item);
                    chip.AddCssClass("package-chip");
                    chip.Selectable = true;
                    chip.Ellipsize = Pango.EllipsizeMode.End;
                    chip.MaxWidthChars = 25;
                    flowBox.Append(chip);
                }
            }

            expander.SetChild(flowBox);
            _detailBox.Append(expander);
        }
    }

    private void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn,
        ColumnViewColumn sizeColumn, ColumnViewColumn versionColumn, ColumnViewColumn repositoryColumn)
    {
        _checkFactory = SignalListItemFactory.New();
        _checkFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var check = CheckButton.New();
            check.MarginStart = 10;
            check.MarginEnd = 10;
            listItem.SetChild(check);

            check.OnToggled += (s, _) =>
            {
                if (listItem.GetItem() is not AlpmPackageGObject current) return;
                current.IsSelected = s.GetActive();
                _installButton.SetSensitive(AnySelected());
            };
        };

        _checkFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;

            var syncing = false;

            syncing = true;
            checkButton.SetActive(pkgObj.IsSelected);
            syncing = false;

            checkButton.OnToggled += OnToggled;
            pkgObj.OnSelectionToggled += OnExternalToggle;
            _checkState.Add(checkButton, new BindState()
            {
                Pkg = pkgObj,
                Toggled = OnToggled,
                External = OnExternalToggle
            });
            return;

            void OnToggled(CheckButton sender, EventArgs e)
            {
                if (syncing) return;
                pkgObj.IsSelected = sender.Active;
                if (sender.Active)
                {
                    ShowPackageDetails(pkgObj);
                }
            }


            void OnExternalToggle(object? s, EventArgs e)
            {
                if (listItem.GetItem() != pkgObj) return;
                syncing = true;
                checkButton.SetActive(pkgObj.IsSelected);
                syncing = false;
            }
        };

        _checkFactory.OnUnbind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetChild() is not CheckButton checkButton) return;
            if (!_checkState.TryGetValue(checkButton, out var state)) return;
            if (state.Toggled is not null) checkButton.OnToggled -= state.Toggled;
            if (state.Pkg is not null && state.External is not null)
            {
                state.Pkg.OnSelectionToggled -= state.External;
            }

            _checkState.Remove(checkButton);
        };

        _checkFactory.OnTeardown += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject ||
                listItem.GetChild() is not CheckButton) return;
            listItem.SetChild(null);
        };

        checkColumn.SetFactory(_checkFactory);

        _nameFactory = SignalListItemFactory.New();
        _nameFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var box = Box.New(Orientation.Horizontal, 6);
            var packageIcon = Image.New();
            packageIcon.PixelSize = 24;
            var label = Label.New(string.Empty);
            var installedIcon = Image.NewFromIconName("object-select-symbolic");

            box.Append(packageIcon);
            box.Append(label);
            box.Append(installedIcon);
            listItem.SetChild(box);
        };
        _nameFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
                listItem.GetChild() is not Box box) return;
            if (pkgObj.Index < 0 || pkgObj.Index >= _packageData.Count) return;
            var pkg = _packageData[pkgObj.Index];

            var packageIcon = (Image)box.GetFirstChild()!;
            var label = (Label)packageIcon.GetNextSibling()!;
            var installedIcon = (Image)label.GetNextSibling()!;

            var iconPath = iconResolverService.GetIconPath(pkg.Name);
            if (!string.IsNullOrEmpty(iconPath) && iconPath != "Unavailable" && File.Exists(iconPath))
            {
                packageIcon.SetFromFile(iconPath);
                packageIcon.Visible = true;
            }
            else
            {
                packageIcon.SetFromIconName("package-x-generic");
                packageIcon.Visible = true;
            }

            label.SetText(pkg.Name);
            label.Halign = Align.Start;
            installedIcon.Visible = pkgObj.IsInstalled;
            installedIcon.TooltipText = "Installed";
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
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
                listItem.GetChild() is not Label label) return;
            if (pkgObj.Index < 0 || pkgObj.Index >= _packageData.Count) return;
            label.SetText(SizeHelper.FormatSize(_packageData[pkgObj.Index].InstalledSize));
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
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
                listItem.GetChild() is not Label label) return;
            if (pkgObj.Index < 0 || pkgObj.Index >= _packageData.Count) return;
            label.SetText(_packageData[pkgObj.Index].Version);
            label.Halign = Align.End;
        };
        versionColumn.SetFactory(_versionFactory);

        _repositoryFactory = SignalListItemFactory.New();
        _repositoryFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };

        _repositoryFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
                listItem.GetChild() is not Label label) return;
            if (pkgObj.Index < 0 || pkgObj.Index >= _packageData.Count) return;

            label.SetText(_packageData[pkgObj.Index].Repository);
            label.Halign = Align.End;
            label.SetMarginEnd(10);
        };
        repositoryColumn.SetFactory(_repositoryFactory);
    }

    private async Task LoadDataAsync(CancellationToken ct = default, int generation = 0)
    {
        try
        {
            var cleared = new TaskCompletionSource();
            GLib.Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested || _loadGeneration != generation)
                {
                    cleared.TrySetResult();
                    return false;
                }

                _filterListModel.SetFilter(null);
                _listStore.RemoveAll();
                _filterListModel.SetFilter(_filter);
                foreach (var r in _packageGObjectRefs)
                {
                    r.Index = -1;
                    r.Dispose();
                }

                _packageGObjectRefs.Clear();
                _packageGObjectRefs.TrimExcess();
                _packageData.Clear();
                _packageData.TrimExcess();
                _currentDetailPkg = null;
                while (_detailBox.GetFirstChild() is { } child) _detailBox.Remove(child);
                cleared.TrySetResult();
                return false;
            });
            await cleared.Task;
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();

            ct.ThrowIfCancellationRequested();

            var packages = await privilegedOperationService.GetAvailablePackagesAsync(_showHiddenCheck.Active);
            _groups = packages.SelectMany(x => x.Groups).Distinct().ToList();
            _groups.Insert(0, "Any");

            ct.ThrowIfCancellationRequested();
            var installedPackages = await privilegedOperationService.GetInstalledPackagesAsync();
            _installedPackageNames = new HashSet<string>(installedPackages.Select(x => x.Name));
            installedPackages.Clear();
            installedPackages.TrimExcess();
            var index = 0;

            GLib.Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested || _loadGeneration != generation)
                {
                    packages.Clear();
                    packages.TrimExcess();
                    return false;
                }

                if (index == 0)
                {
                    _groupsStringList = StringList.New(_groups.ToArray());
                    _groupDropDown.SetModel(_groupsStringList);
                }

                const int batchSize = 1000;
                var batch = new List<AlpmPackageGObject>();
                while (index < packages.Count && batch.Count < batchSize)
                {
                    var pkg = packages[index];
                    index++;
                    var dataIndex = _packageData.Count;
                    _packageData.Add(pkg);
                    var pkgObj = AlpmPackageGObject.NewWithProperties([]);
                    pkgObj.Index = dataIndex;
                    pkgObj.IsInstalled = _installedPackageNames.Contains(pkg.Name);
                    _packageGObjectRefs.Add(pkgObj);
                    batch.Add(pkgObj);
                }

                // ReSharper disable once CoVariantArrayConversion
                _listStore.Splice(_listStore.GetNItems(), 0, batch.ToArray(), (uint)batch.Count);

                if (_listStore.GetNItems() > 0 && _selectionModel.GetSelected() == uint.MaxValue)
                    _selectionModel.SetSelected(0);

                if (index < packages.Count) return true;
                packages.Clear();
                packages.TrimExcess();
                return false;
            });
        }
        catch (OperationCanceledException)
        {
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

    private bool FilterPackage(GObject.Object obj)
    {
        if (obj is not AlpmPackageGObject pkgObj) return false;
        if (pkgObj.Index < 0 || pkgObj.Index >= _packageData.Count) return false;
        var pkg = _packageData[pkgObj.Index];

        return PackageSearch.MatchesGroup(pkg.Groups, _selectedGroup) &&
               PackageSearch.MatchesNameOrDescription(pkg.Name, pkg.Description, _searchText);
    }


    private async Task InstallSelectedAsync()
    {
        var selectedPackages = new List<string>();
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AlpmPackageGObject { IsSelected: true } pkgObj &&
                pkgObj.Index >= 0 && pkgObj.Index < _packageData.Count)
            {
                selectedPackages.Add(_packageData[pkgObj.Index].Name);
            }
        }

        if (selectedPackages.Count != 0)
        {
            OperationResult? result = null;

            try
            {
                if (!configService.LoadConfig().NoConfirm)
                {
                    var message = string.Join("\n", selectedPackages);
                    var performUpgradeForDialog = _upgradeCheck.GetActive();

                    if (performUpgradeForDialog)
                    {
                        var updatesNeeded = await unprivilegedOperationService.CheckForStandardApplicationUpdates();
                        if (updatesNeeded.Count > 0)
                        {
                            message += "\n\n--- Packages to Upgrade ---\n";
                            message += string.Join("\n",
                                updatesNeeded.Select(u => $"{u.Name}: {u.CurrentVersion} -> {u.NewVersion}"));
                        }
                    }

                    var args = new GenericQuestionEventArgs(
                        "Install Packages?", message
                    );

                    genericQuestionService.RaiseQuestion(args);
                    if (!await args.ResponseTask)
                    {
                        return;
                    }
                }

                lockoutService.Show($"Installing...");
                var performUpgrade = _upgradeCheck.GetActive();
                result = await privilegedOperationService.InstallPackagesAsync(selectedPackages, performUpgrade);
                Reload();
            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to install packages: {e.Message}");
            }
            finally
            {
                lockoutService.Hide();
            }

            if (result == null)
            {
                return;
            }

            if (result.Success)
            {
                var args = new ToastMessageEventArgs(
                    $"Installed {selectedPackages.Count} Package(s)"
                );

                genericQuestionService.RaiseToastMessage(args);
                return;
            }

            ShowInstallFailureDialog(selectedPackages, result);
        }
    }

    private void ShowInstallFailureDialog(IReadOnlyCollection<string> selectedPackages, OperationResult result)
    {
        var dialogArgs = StandardInstallFailureDialog.Create(
            selectedPackages,
            LogHelpers.BuildFailureSummary(result),
            () => ExportInstallLogAsync(selectedPackages, result));

        genericQuestionService.RaiseDialog(dialogArgs);
    }

    private async Task<bool> ExportInstallLogAsync(IReadOnlyCollection<string> selectedPackages, OperationResult result)
    {
        try
        {
            var dialog = FileDialog.New();
            dialog.SetTitle("Export Shelly install log");
            dialog.SetInitialName(LogHelpers.CreateSuggestedLogFileName(selectedPackages, "shelly"));

            var filter = FileFilter.New();
            filter.SetName("Log Files (*.log)");
            filter.AddPattern("*.log");

            var filters = Gio.ListStore.New(FileFilter.GetGType());
            filters.Append(filter);
            dialog.SetFilters(filters);

            var file = await dialog.SaveAsync((Window)_overlay.GetRoot()!);
            if (file is null)
            {
                return false;
            }

            var path = file.GetPath();
            if (string.IsNullOrWhiteSpace(path))
            {
                return false;
            }

            await File.WriteAllTextAsync(path, LogHelpers.BuildInstallLog(selectedPackages, result, "aur"));

            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs("Exported Shelly install log"));
            return true;
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to export Shelly install log: {e.Message}");
            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs("Failed to export Shelly install log"));
            return false;
        }
    }

    private async Task InstallLocalPackage()
    {
        try
        {
            var dialog = FileDialog.New();
            dialog.SetTitle("Install Local Package");

            var filter = FileFilter.New();
            filter.SetName("Local package files (\"*.xz\", \"*.gz\", \"*.zst\")");
            filter.AddPattern("*.xz");
            filter.AddPattern("*.gz");
            filter.AddPattern("*.zst");

            var filters = Gio.ListStore.New(FileFilter.GetGType());
            filters.Append(filter);
            dialog.SetFilters(filters);

            var file = await dialog.OpenAsync((Window)_overlay.GetRoot()!);

            if (file is not null)
            {
                lockoutService.Show($"Installing local package...");
                var result = await privilegedOperationService.InstallLocalPackageAsync(file.GetPath()!);
                if (!result.Success)
                {
                    Console.WriteLine($"Failed to install local package: {result.Error}");
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to install local package: {ex.Message}");
        }
        finally
        {
            lockoutService.Hide();

            var args = new ToastMessageEventArgs(
                $"Installed local package"
            );
            genericQuestionService.RaiseToastMessage(args);
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
        _sub?.Dispose();
        _cts.Cancel();
        _cts.Dispose();
        _listStore.RemoveAll();
        foreach (var r in _packageGObjectRefs)
        {
            r.Index = -1;
            r.Dispose();
        }

        _packageGObjectRefs.Clear();
        _packageData.Clear();
        _groups.Clear();
        _installedPackageNames.Clear();
        _currentDetailPkg = null;
    }
}