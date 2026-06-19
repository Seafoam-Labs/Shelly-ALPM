using System.Runtime.CompilerServices;
using Gtk;
using Shelly.Gtk.DataStores;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using static Shelly.Gtk.Helpers.PackageColumnViewSorter;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.Icons;
using Shelly.Gtk.Services.PackageTraversal;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;
using Shelly.Gtk.Windows.Dialog;
using static Shelly.GTK.Resources.Translations;
using ListStore = Gio.ListStore;

// ReSharper disable NotAccessedField.Local
// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.Packages;

public sealed class PackageInstall(
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
    private ScrolledWindow _scroller = null!;
    private CancellationTokenSource _cts = new();
    private int _loadGeneration;
    private SingleSelection _selectionModel = null!;
    private ListStore _listStore = null!;
    private FilterListModel _filterListModel = null!;
    private CustomFilter _filter = null!;
    private string _searchText = string.Empty;
    private List<string> _groups = [];
    private string _selectedGroup = T("Any");

    private readonly List<AlpmPackageGObject> _packageGObjectRefs = [];
    private readonly List<AlpmPackageDto> _packageData = [];

    private Button _installButton = null!;
    private SearchEntry _searchEntry = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private ColumnViewColumn _repositoryColumn = null!;
    private ColumnViewColumn _sizeColumn = null!;
    private ColumnViewSorter _columnViewSorter = null!;
    private DropDown _groupDropDown = null!;
    private CheckButton _upgradeCheck = null!;
    private CheckButton _showHiddenCheck = null!;

    private Revealer _detailRevealer = null!;
    private Box _detailBox = null!;
    private HashSet<string> _installedPackageNames = [];
    private static readonly ConditionalWeakTable<CheckButton, BindState> CheckState = new();

    private Box _loadingOverlay = null!;
    private Spinner _loadingSpinner = null!;
    private Label _errorLabel = null!;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Package/PackageWindow.ui"), -1);
        builder.TranslationDomain = Domain;
        _overlay = (Overlay)builder.GetObject("PackageWindow")!;
        var columnView = (ColumnView)builder.GetObject("package_column_view")!;
        _scroller = (ScrolledWindow)columnView.GetParent()!;
        var checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        checkColumn.Resizable = true;
        _nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        _nameColumn.Resizable = true;
        _sizeColumn = (ColumnViewColumn)builder.GetObject("size_column")!;
        _sizeColumn.Resizable = true;
        _versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        _versionColumn.Resizable = true;
        _repositoryColumn = (ColumnViewColumn)builder.GetObject("repository_column")!;
        _repositoryColumn.Resizable = true;
        _installButton = (Button)builder.GetObject("install_button")!;
        _installButton.SetSensitive(false);
        var localInstallButton = (Button)builder.GetObject("install_local_button")!;
        _searchEntry = (SearchEntry)builder.GetObject("search_entry")!;
        _detailRevealer = (Revealer)builder.GetObject("detail_revealer")!;
        _detailBox = (Box)builder.GetObject("detail_box")!;
        _groupDropDown = (DropDown)builder.GetObject("grouping_selection")!;
        _upgradeCheck = (CheckButton)builder.GetObject("upgrade_check")!;
        _showHiddenCheck = (CheckButton)builder.GetObject("show_hidden_check")!;

        var config = configService.LoadConfig();
        _upgradeCheck.Active = config.PackageInstallUpgrade;
        _showHiddenCheck.Active = config.PackageInstallShowHidden;

        _loadingOverlay = (Box)builder.GetObject("loading_overlay")!;
        _loadingSpinner = (Spinner)builder.GetObject("loading_spinner")!;
        _errorLabel = (Label)builder.GetObject("error_label")!;

        _listStore = ListStore.New(AlpmPackageGObject.GetGType());
        _filter = PackageSearch.CreateSafeFilter(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _selectionModel.CanUnselect = true;
        _selectionModel.Autoselect = false;
        columnView.SetModel(_selectionModel);

        SetupColumns(checkColumn, _nameColumn, _sizeColumn, _versionColumn, _repositoryColumn);

        _nameColumn.Sorter = CustomSorter.New<AlpmPackageGObject>((_, _) => 0);
        _repositoryColumn.Sorter = CustomSorter.New<AlpmPackageGObject>((_, _) => 0);
        _versionColumn.Sorter = CustomSorter.New<AlpmPackageGObject>((_, _) => 0);
        _sizeColumn.Sorter = CustomSorter.New<AlpmPackageGObject>((_, _) => 0);

        _columnViewSorter = (ColumnViewSorter)columnView.GetSorter()!;

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
                order,
                _searchText
            );
        };

        ColumnViewHelper.AlignColumnHeader(columnView, 1, Align.Start);
        ColumnViewHelper.AlignColumnHeader(columnView, 2, Align.End);
        ColumnViewHelper.AlignColumnHeader(columnView, 3, Align.End);
        ColumnViewHelper.AlignColumnHeader(columnView, 4, Align.End);

        columnView.OnRealize += (_, _) => { Reload(); };
        columnView.OnActivate += (_, _) =>
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
            }
        };
        _searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchText = _searchEntry.GetText();
            ApplyFilter();
            ReapplySort();
            _selectionModel.SetSelected(uint.MaxValue);
            ScrollToTop();
        };
        _installButton.OnClicked += (_, _) => { _ = InstallSelectedAsync(); };
        _installButton.CanFocus = true;
        _installButton.ReceivesDefault = true;

        var shortcutController = ShortcutController.New();
        shortcutController.Scope = ShortcutScope.Global;
        shortcutController.PropagationPhase = PropagationPhase.Capture;

        var triggers = new[] { "Return", "KP_Enter", "space", "<Control>f" };
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

        localInstallButton.OnClicked += (_, _) => { _ = InstallLocalPackage(); };
        _upgradeCheck.OnToggled += (_, _) =>
        {
            var updatedConfig = configService.LoadConfig();
            updatedConfig.PackageInstallUpgrade = _upgradeCheck.Active;
            configService.SaveConfig(updatedConfig);
        };
        _showHiddenCheck.OnToggled += (_, _) =>
        {
            var updatedConfig = configService.LoadConfig();
            updatedConfig.PackageInstallShowHidden = _showHiddenCheck.Active;
            configService.SaveConfig(updatedConfig);
            Reload();
        };

        _groupDropDown.OnNotify += (_, args) =>
        {
            if (args.Pspec.GetName() != "selected") return;
            var idx = _groupDropDown.GetSelected();
            if (idx != uint.MaxValue && _groupDropDown.GetModel()?.GetObject(idx) is StringObject item)
            {
                _selectedGroup = item.GetString();
                ApplyFilter();
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
        
        if (column == _sizeColumn)
            return PackageSortColumn.Size;

        return null;
    }

    public void Reload()
    {
        var old = Interlocked.Exchange(ref _cts, new CancellationTokenSource());
        old.Cancel();
        old.Dispose();
        Interlocked.Increment(ref _loadGeneration);
        _ = LoadDataAsync(_loadGeneration, _cts.Token);
    }

    private void ShowPackageDetails(AlpmPackageGObject pkgObj)
    {
        if (pkgObj.Index < 0 || pkgObj.Index >= _packageData.Count) return;

        var pkg = _packageData[pkgObj.Index];

        while (_detailBox.GetFirstChild() is { } child)
        {
            _detailBox.Remove(child);
        }

        var backButton = Button.New();
        backButton.SetIconName("go-next-symbolic");
        backButton.Halign = Align.Start;
        backButton.AddCssClass("flat");
        backButton.TooltipText = T("Close details");
        backButton.OnClicked += (_, _) =>
        {
            _selectionModel.UnselectItem(_selectionModel.GetSelected());
            _detailRevealer.SetTransitionType(RevealerTransitionType.SlideLeft);
            _detailRevealer.SetRevealChild(false);
        };
        _detailBox.Append(backButton);

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

        AddDetail(T("Version"), pkg.Version);
        AddDetail(T("Repository"), pkg.Repository);
        AddDetail(T("Size"), SizeHelpers.FormatSize(pkg.InstalledSize));
        AddDetail(T("Installed Size"), SizeHelpers.FormatSize(pkg.InstalledSize));
        AddDetail(T("Build Date"), pkg.BuildDate.ToString("yyyy-MM-dd HH:mm:ss"));
        if (!string.IsNullOrEmpty(pkg.Url))
        {
            var row = Box.New(Orientation.Horizontal, 12);
            row.MarginBottom = 4;
            var labelWidget = Label.New(T("URL:"));
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
            AddChipList(T("Depends"), pkg.Depends);
        }

        if (pkg.OptDepends.Count > 0)
        {
            AddChipList(T("Optional Deps"), pkg.OptDepends, true);
        }

        var names = PackageTraversalService.FetchInverseFullDependencyPackageInformation(pkg.Name, _packageData);
        if (names.Count > 0)
        {
            AddChipList(T("Required By"), names);
        }

        if (pkg.Licenses.Count > 0)
            AddDetail(T("Licenses"), string.Join(", ", pkg.Licenses));
        if (pkg.Provides.Count > 0)
            AddDetail(T("Provides"), string.Join(", ", pkg.Provides));
        if (pkg.Conflicts.Count > 0)
            AddDetail(T("Conflicts"), string.Join(", ", pkg.Conflicts));
        if (pkg.Groups.Count > 0)
            AddDetail(T("Groups"), string.Join(", ", pkg.Groups));

        if (configService.LoadConfig().WebViewEnabled && pkg.Depends.Count > 0)
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

        _detailRevealer.SetRevealChild(true);
        return;

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

        void AddChipList(string label, IReadOnlyList<string> items, bool isOptional = false)
        {
            var expander = Expander.New($"{label} ({items.Count})");
            expander.AddCssClass("package-detail-expander");
            expander.Hexpand = false;

            var flowBox = FlowBox.New();
            flowBox.SelectionMode = SelectionMode.None;
            flowBox.MarginTop = 8;
            flowBox.MarginBottom = 2;
            flowBox.ColumnSpacing = 6;
            flowBox.RowSpacing = 6;
            flowBox.Halign = Align.Fill;
            flowBox.Valign = Align.Start;
            flowBox.MaxChildrenPerLine = isOptional ? 1u : 10u;
            flowBox.MinChildrenPerLine = 1;

            foreach (var item in items)
            {
                if (isOptional)
                {
                    var optDepName = item.Split(':')[0].Trim();
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
        var checkFactory = SignalListItemFactory.New();
        checkFactory.OnSetup += (_, args) =>
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

        checkFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;

            checkButton.SetActive(pkgObj.IsSelected);
            var syncing = false;

            checkButton.OnToggled += OnToggled;
            pkgObj.OnSelectionToggled += OnExternalToggle;
            CheckState.Add(checkButton, new BindState()
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

        checkFactory.OnUnbind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetChild() is not CheckButton checkButton) return;
            if (!CheckState.TryGetValue(checkButton, out var state)) return;
            if (state.Toggled is not null) checkButton.OnToggled -= state.Toggled;
            if (state.Pkg is not null && state.External is not null)
            {
                state.Pkg.OnSelectionToggled -= state.External;
            }

            CheckState.Remove(checkButton);
        };

        checkFactory.OnTeardown += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject ||
                listItem.GetChild() is not CheckButton) return;
            listItem.SetChild(null);
        };

        checkColumn.SetFactory(checkFactory);

        var nameFactory = SignalListItemFactory.New();
        nameFactory.OnSetup += (_, args) =>
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
        nameFactory.OnBind += (_, args) =>
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
        nameColumn.SetFactory(nameFactory);

        var sizeFactory = SignalListItemFactory.New();
        sizeFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        sizeFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
                listItem.GetChild() is not Label label) return;
            if (pkgObj.Index < 0 || pkgObj.Index >= _packageData.Count) return;
            label.SetText(SizeHelpers.FormatSize(_packageData[pkgObj.Index].InstalledSize));
            label.Halign = Align.End;
        };
        sizeColumn.SetFactory(sizeFactory);

        var versionFactory = SignalListItemFactory.New();
        versionFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        versionFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
                listItem.GetChild() is not Label label) return;
            if (pkgObj.Index < 0 || pkgObj.Index >= _packageData.Count) return;
            label.SetText(_packageData[pkgObj.Index].Version);
            label.Halign = Align.End;
        };
        versionColumn.SetFactory(versionFactory);

        var repositoryFactory = SignalListItemFactory.New();
        repositoryFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };

        repositoryFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject pkgObj ||
                listItem.GetChild() is not Label label) return;
            if (pkgObj.Index < 0 || pkgObj.Index >= _packageData.Count) return;

            label.SetText(_packageData[pkgObj.Index].Repository);
            label.Halign = Align.End;
            label.SetMarginEnd(10);
        };
        repositoryColumn.SetFactory(repositoryFactory);
    }

    private async Task LoadDataAsync(int generation = 0, CancellationToken ct = default)
    {
        if (_loadGeneration != generation) return;
        OverlayHelper.ShowLoading(_loadingOverlay, _loadingSpinner, _errorLabel);

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
                while (_detailBox.GetFirstChild() is { } child) _detailBox.Remove(child);
                cleared.TrySetResult();
                if (_listStore.GetNItems() > 0)
                {
                    _selectionModel.SetSelected(0);
                    var firstItem = _selectionModel.GetSelectedItem();
                    if (firstItem is AlpmPackageGObject pkgObj)
                    {
                        ShowPackageDetails(_packageGObjectRefs[pkgObj.Index]);
                    }
                }

                return false;
            });
            await cleared.Task;
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();

            ct.ThrowIfCancellationRequested();

            var packages = await privilegedOperationService.GetAvailablePackagesAsync(_showHiddenCheck.Active);
            _groups = packages.SelectMany(x => x.Groups).Distinct().ToList();
            _groups.Insert(0, T("Any"));

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
                    if (_loadGeneration == generation)
                    {
                        OverlayHelper.HideLoading(_loadingOverlay, _loadingSpinner);
                    }
                    packages.Clear();
                    packages.TrimExcess();
                    return false;
                }

                if (index == 0)
                {
                    var groupsStringList = StringList.New(_groups.ToArray());
                    _groupDropDown.SetModel(groupsStringList);
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
                var count = packages.Count;
                packages.Clear();
                packages.TrimExcess();

                if (_loadGeneration == generation)
                {
                    _loadingSpinner.SetSpinning(false);
                    _loadingSpinner.SetVisible(false);

                    if (count == 0)
                    {
                        _errorLabel.SetVisible(true);
                        _loadingOverlay.SetVisible(true);
                    }
                    else
                    {
                        OverlayHelper.HideLoading(_loadingOverlay, _loadingSpinner);
                    }
                }
                return false;

            });
        }
        catch (OperationCanceledException)
        {
            if (_loadGeneration == generation)
            {
                OverlayHelper.HideLoading(_loadingOverlay, _loadingSpinner);
            }
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load packages: {e.Message}");
            if (_loadGeneration == generation)
            {
                OverlayHelper.ShowLoading(_loadingOverlay, _loadingSpinner, _errorLabel);
                _errorLabel.SetText(T("Failed to load packages."));
                _errorLabel.SetVisible(true);
            }
        }
    }

    private void ApplyFilter()
    {
        _filter.Changed(FilterChange.Different);
    }

    private void ScrollToTop()
    {
        GLib.Functions.IdleAdd(0, () =>
        {
            var frames = 0;
            _scroller.AddTickCallback((_, _) =>
            {
                var vadj = _scroller.GetVadjustment();
                if (vadj is not null) vadj.SetValue(vadj.GetLower());
                var hadj = _scroller.GetHadjustment();
                if (hadj is not null) hadj.SetValue(hadj.GetLower());
                return ++frames < 3;
            });
            return false;
        });
    }

    private void ReapplySort()
    {
        var primaryColumn = _columnViewSorter.GetPrimarySortColumn();
        var sortColumn = primaryColumn is null ? null : GetSortColumn(primaryColumn);
        var order = _columnViewSorter.GetPrimarySortOrder();
        Sort(
            _listStore,
            _packageData,
            _packageGObjectRefs,
            sortColumn ?? PackageSortColumn.Name,
            order,
            _searchText
        );
    }

    private bool FilterPackage(GObject.Object obj)
    {
        if (obj is not AlpmPackageGObject pkgObj) return false;
        if (pkgObj.Index < 0 || pkgObj.Index >= _packageData.Count) return false;
        var pkg = _packageData[pkgObj.Index];

        return PackageSearch.MatchesGroup(pkg.Groups, _selectedGroup) &&
               PackageSearch.Matches(pkg.Name, pkg.Description, _searchText);
    }


    private async Task InstallSelectedAsync()
    {
        var selectedPackages = new List<string>();
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AlpmPackageGObject { IsSelected: true, Index: >= 0 } pkgObj &&
                pkgObj.Index < _packageData.Count)
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
                            message += "\n\n" + T("--- Packages to Upgrade ---") + "\n";
                            message += string.Join("\n",
                                updatesNeeded.Select(u => $"{u.Name}: {u.CurrentVersion} -> {u.NewVersion}"));
                        }
                    }

                    var args = new GenericQuestionEventArgs(
                        T("Install Packages?"), message
                    );

                    genericQuestionService.RaiseQuestion(args);
                    if (!await args.ResponseTask)
                    {
                        return;
                    }
                }

                OverlayHelper.ShowLoading(_loadingOverlay, _loadingSpinner, _errorLabel);

                lockoutService.Show(T("Installing..."));
                var performUpgrade = _upgradeCheck.GetActive();
                result = await privilegedOperationService.InstallPackagesAsync(selectedPackages, performUpgrade);
                Reload();
            }
            catch (Exception e)
            {
                OverlayHelper.HideLoading(_loadingOverlay, _loadingSpinner);
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
                    T("Installed {0} Package(s)", selectedPackages.Count)
                );

                genericQuestionService.RaiseToastMessage(args);
            }
        }
    }

    private async Task InstallLocalPackage()
    {
        try
        {
            var dialog = FileDialog.New();
            dialog.SetTitle(T("Install Local Package"));

            var filter = FileFilter.New();
            filter.SetName(T("Local package files (\"*.gz\", \"*.zst\")"));
            filter.AddPattern("*.gz");
            filter.AddPattern("*.zst");

            var filters = ListStore.New(FileFilter.GetGType());
            filters.Append(filter);
            dialog.SetFilters(filters);

            var file = await dialog.OpenAsync((Window)_overlay.GetRoot()!);

            if (file?.GetPath() is { } filePath)
            {
                lockoutService.Show(T("Installing local package..."));
                var result = await privilegedOperationService.InstallLocalPackageAsync(filePath);
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

            var args = new ToastMessageEventArgs(T("Installed local package"));
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
    }
}
