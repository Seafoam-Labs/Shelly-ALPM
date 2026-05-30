using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Enums;
using static Shelly.GTK.Resources.Translations;
using static Shelly.Gtk.Helpers.PackageColumnViewSorter;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.Icons;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.Packages;

public class PackageUpdate(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    ILockoutService lockoutService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService,
    IIconResolverService iconResolverService,
    IDirtyService dirtyService) : IShellyWindow, IReloadable
{
    private DirtySubscription? _sub;
    public string[] ListensTo => [DirtyScopes.NativeUpdates, DirtyScopes.NativeInstalled, DirtyScopes.News];
    private CancellationTokenSource _cts = new();
    private int _loadGeneration;
    private bool _suppressToggleConfirmation;
    private Overlay _box = null!;
    private ColumnView _columnView = null!;
    private SingleSelection _selectionModel = null!;
    private Gio.ListStore _listStore = null!;
    private FilterListModel _filterListModel = null!;
    private CustomFilter _filter = null!;
    private string _searchText = string.Empty;

    private SignalListItemFactory _checkFactory = null!;
    private SignalListItemFactory _nameFactory = null!;
    private SignalListItemFactory _oldVersionFactory = null!;
    private SignalListItemFactory _sizeDiffFactory = null!;
    private SignalListItemFactory _versionFactory = null!;
    private readonly List<AlpmUpdateGObject> _packageGObjectRefs = [];

    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _oldColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private ColumnViewColumn _sizeDiffColumn = null!;

    private ColumnViewSorter _columnViewSorter = null!;

    private Button _refreshButton = null!;
    private Button _updateButton = null!;
    private Label _noPackagesLabel = null!;
    private CheckButton _showHiddenCheck = null!;

    private Revealer _detailRevealer = null!;
    private Box _detailBox = null!;
    private Box _loadingOverlay = null!;
    private Spinner _loadingSpinner = null!;
    private Label _errorLabel = null!;
    private HashSet<string> _installedPackageNames = [];

    public Widget CreateWindow()
    {
        var builder = Builder.New();
        builder.TranslationDomain = Domain;
        builder.AddFromString(ResourceHelper.LoadUiFile("UiFiles/Package/UpdateWindow.ui"), -1);
        _box = (Overlay)builder.GetObject("UpdateWindow")!;
        _columnView = (ColumnView)builder.GetObject("package_grid")!;
        var searchEntry = (SearchEntry)builder.GetObject("search_entry")!;

        _checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        _checkColumn.Resizable = true;
        _nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        _nameColumn.Resizable = true;
        _oldColumn = (ColumnViewColumn)builder.GetObject("old_column")!;
        _oldColumn.Resizable = true;
        _versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        _versionColumn.Resizable = true;
        _sizeDiffColumn = (ColumnViewColumn)builder.GetObject("size_diff_column")!;
        _sizeDiffColumn.Resizable = true;
        _refreshButton = (Button)builder.GetObject("sync_button")!;
        _updateButton = (Button)builder.GetObject("update_button")!;
        _showHiddenCheck = (CheckButton)builder.GetObject("show_hidden_check")!;
        _noPackagesLabel = (Label)builder.GetObject("no_packages_label")!;
        var config = configService.LoadConfig();
        _showHiddenCheck.Active = config.PackageUpdateShowHidden;
        _noPackagesLabel.Label_ = T("<span size='large'>System packages are up to date</span>");
        _noPackagesLabel.Visible = false;
        _detailRevealer = (Revealer)builder.GetObject("detail_revealer")!;
        _detailBox = (Box)builder.GetObject("detail_box")!;
        _loadingOverlay = (Box)builder.GetObject("loading_overlay")!;
        _loadingSpinner = (Spinner)builder.GetObject("loading_spinner")!;
        _errorLabel = (Label)builder.GetObject("error_label")!;
        _listStore = Gio.ListStore.New(AlpmUpdateGObject.GetGType());
        _filter = PackageSearch.CreateSafeFilter(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _selectionModel.CanUnselect = true;
        _selectionModel.Autoselect = false;
        _columnView.SetModel(_selectionModel);

        SetupColumns(_checkColumn, _nameColumn, _sizeDiffColumn, _oldColumn, _versionColumn);

        // Creating sorter
        _nameColumn.Sorter = CustomSorter.New<AlpmPackageGObject>((a, b) => 0);

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
        ColumnViewHelper.AlignColumnHeader(_columnView, 3, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 4, Align.End);

        var shortcutController = ShortcutController.New();
        shortcutController.Scope = ShortcutScope.Global;
        shortcutController.PropagationPhase = PropagationPhase.Capture;

        var searchTrigger = "<Control>f";

        var action = CallbackAction.New((_, _) =>
        {
            searchEntry.GrabFocus();
            return true;
        });

        _box.AddController(shortcutController);
        shortcutController.AddShortcut(Shortcut.New(ShortcutTrigger.ParseString(searchTrigger), action));


        _columnView.OnRealize += (_, _) => { Reload(); };
        _columnView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            if (item is AlpmUpdateGObject pkgObj)
            {
                if (pkgObj.IsSelected)
                {
                    _ = ConfirmPartialUpdateAsync(() =>
                    {
                        pkgObj.ToggleSelection();
                        _updateButton.SetSensitive(AnySelected());
                    });
                }
                else
                {
                    pkgObj.ToggleSelection();
                    _updateButton.SetSensitive(AnySelected());
                }
            }
        };
        searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchText = searchEntry.GetText();
            ApplyFilter();
        };
        _selectionModel.OnSelectionChanged += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            _detailRevealer.SetTransitionType(RevealerTransitionType.SlideLeft);
            if (item is AlpmUpdateGObject pkgObj)
            {
                ShowPackageDetails(pkgObj);
            }
            else
            {
                _detailRevealer.SetRevealChild(false);
            }
        };
        _updateButton.OnClicked += (_, _) => { _ = UpdateSelectedAsync(); };
        _refreshButton.OnClicked += (_, _) => { Reload(); };
        _showHiddenCheck.OnToggled += (_, _) =>
        {
            var updatedConfig = configService.LoadConfig();
            updatedConfig.PackageUpdateShowHidden = _showHiddenCheck.Active;
            configService.SaveConfig(updatedConfig);
            Reload();
        };

        _sub = DirtySubscription.Attach(dirtyService, this);
        return _box;
    }

    private PackageSortColumn? GetSortColumn(ColumnViewColumn column)
    {
        if (column == _nameColumn)
            return PackageSortColumn.Name;

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

    private void ShowPackageDetails(AlpmUpdateGObject pkgObj)
    {
        if (pkgObj.Package == null) return;

        var pkg = pkgObj.Package;

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
            var texture = Gdk.Texture.NewFromFilename(iconPath);
            iconImage.SetFromPaintable(texture);
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

        AddDetail(T("Current"), pkg.CurrentVersion);
        AddDetail(T("New"), pkg.NewVersion);
        AddDetail(T("Download"), SizeHelpers.FormatSize(pkg.DownloadSize));
        AddDetail(T("Size Diff"), SizeHelpers.FormatSize(pkg.SizeDifference));
        AddDetail(T("Repository"), pkg.Repository);
        AddDetail(T("Size"), SizeHelpers.FormatSize(pkg.InstalledSize));
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

        if (pkg.Licenses.Count > 0)
            AddDetail(T("Licenses"), string.Join(", ", pkg.Licenses));
        if (pkg.Provides.Count > 0)
            AddDetail(T("Provides"), string.Join(", ", pkg.Provides));
        if (pkg.Conflicts.Count > 0)
            AddDetail(T("Conflicts"), string.Join(", ", pkg.Conflicts));
        if (pkg.Groups.Count > 0)
            AddDetail(T("Groups"), string.Join(", ", pkg.Groups));

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
                        if (obj is not AlpmUpdateGObject depObj || depObj.Package == null) continue;
                        if (depObj.Package.Name.Contains(dep))
                            dictionary.TryAdd(depObj.Package.Name, depObj.Package.Depends);
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
        ColumnViewColumn sizeDiffColumn, ColumnViewColumn oldColumn, ColumnViewColumn versionColumn)
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
                if (listItem.GetItem() is not AlpmUpdateGObject pkgObj) return;

                if (_suppressToggleConfirmation)
                {
                    pkgObj.IsSelected = s.GetActive();
                    _updateButton.SetSensitive(AnySelected());
                    return;
                }

                if (!s.GetActive())
                {
                    s.SetActive(true);
                    var __ = ConfirmPartialUpdateAsync(() =>
                    {
                        _suppressToggleConfirmation = true;
                        s.SetActive(false);
                        _suppressToggleConfirmation = false;
                        _updateButton.SetSensitive(AnySelected());
                    });
                }
                else
                {
                    pkgObj.IsSelected = true;
                    _updateButton.SetSensitive(AnySelected());
                }
            };
        };

        _checkFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmUpdateGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;

            checkButton.SetActive(pkgObj.IsSelected);

            pkgObj.OnSelectionToggled += OnExternalToggle;
            return;

            void OnExternalToggle(object? s, EventArgs e)
            {
                if (listItem.GetItem() == pkgObj)
                {
                    checkButton.SetActive(pkgObj.IsSelected);
                    _updateButton.SetSensitive(AnySelected());
                }
            }
        };

        _checkFactory.OnUnbind += (_, _) => { };

        _checkFactory.OnTeardown += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
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

            box.Append(packageIcon);
            box.Append(label);
            listItem.SetChild(box);
        };
        _nameFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmUpdateGObject { Package: { } pkg } ||
                listItem.GetChild() is not Box box) return;

            var packageIcon = (Image)box.GetFirstChild()!;
            var label = (Label)packageIcon.GetNextSibling()!;

            var iconPath = iconResolverService.GetIconPath(pkg.Name);
            if (!string.IsNullOrEmpty(iconPath) && iconPath != "Unavailable" && File.Exists(iconPath))
            {
                var texture = Gdk.Texture.NewFromFilename(iconPath);
                packageIcon.SetFromPaintable(texture);
                packageIcon.Visible = true;
            }
            else
            {
                packageIcon.SetFromIconName("package-x-generic");
                packageIcon.Visible = true;
            }

            label.SetText(pkg.Name);
            label.Halign = Align.Start;
        };
        nameColumn.SetFactory(_nameFactory);

        _sizeDiffFactory = SignalListItemFactory.New();
        _sizeDiffFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        _sizeDiffFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmUpdateGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(SizeHelpers.FormatSize(pkg.SizeDifference));
            label.Halign = Align.End;
        };
        sizeDiffColumn.SetFactory(_sizeDiffFactory);

        _oldVersionFactory = SignalListItemFactory.New();
        _oldVersionFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        _oldVersionFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmUpdateGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.CurrentVersion);
            label.Halign = Align.End;
        };
        oldColumn.SetFactory(_oldVersionFactory);

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
            if (listItem.GetItem() is not AlpmUpdateGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.NewVersion);
            label.Halign = Align.End;
            label.SetMarginEnd(10);
        };
        versionColumn.SetFactory(_versionFactory);
    }

    private bool FilterPackage(GObject.Object obj)
    {
        if (obj is not AlpmUpdateGObject { Package: { } pkg })
            return false;

        return PackageSearch.MatchesName(pkg.Name, _searchText);
    }

    private async Task LoadDataAsync(CancellationToken ct = default, int generation = 0)
    {
        if (ct.IsCancellationRequested || _loadGeneration != generation) return;
        OverlayHelper.ShowLoading(_loadingOverlay, _loadingSpinner, _errorLabel);

        try
        {
            var packages =
                await unprivilegedOperationService.CheckForStandardApplicationUpdates(_showHiddenCheck.Active);
            var installedPackages = await privilegedOperationService.GetInstalledPackagesAsync();
            _installedPackageNames = new HashSet<string>(installedPackages.Select(x => x.Name));
            ct.ThrowIfCancellationRequested();
            GLib.Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested || _loadGeneration != generation) return false;

                OverlayHelper.HideLoading(_loadingOverlay, _loadingSpinner);

                _filterListModel.SetFilter(null);
                _listStore.RemoveAll();
                _packageGObjectRefs.Clear();
                _filterListModel.SetFilter(_filter);
                _detailRevealer.SetRevealChild(false);

                foreach (var package in packages)
                {
                    var pkgObj = AlpmUpdateGObject.NewWithProperties([]);
                    pkgObj.Package = package;
                    _packageGObjectRefs.Add(pkgObj);
                    _listStore.Append(pkgObj);
                }

                _noPackagesLabel.Visible = packages.Count == 0;
                _updateButton.SetSensitive(AnySelected());

                if (_listStore.GetNItems() > 0)
                {
                    _selectionModel.SetSelected(0);
                    var firstItem = _selectionModel.GetSelectedItem();
                    if (firstItem is AlpmUpdateGObject pkgObj)
                    {
                        ShowPackageDetails(pkgObj);
                    }
                }

                return false;
            });
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load packages: {e.Message}");
            if (!ct.IsCancellationRequested && _loadGeneration == generation)
            {
                OverlayHelper.HideLoading(_loadingOverlay, _loadingSpinner);
                _errorLabel.Visible = true;
            }
        }
    }

    private async Task ConfirmPartialUpdateAsync(Action onConfirmed)
    {
        var args = new GenericQuestionEventArgs(
            T("Partial Update Warning"),
            T("It is not advised you do partial system updates. Are you sure you want to continue?")
        );

        genericQuestionService.RaiseQuestion(args);
        if (await args.ResponseTask)
        {
            onConfirmed();
        }
    }

    private void ApplyFilter()
    {
        _filter.Changed(FilterChange.Different);
    }

    private async Task UpdateSelectedAsync()
    {
        var selectedPackages = new List<string>();
        var selectedPackageUpdates = new List<AlpmPackageUpdateDto>();
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AlpmUpdateGObject { IsSelected: true, Package: not null } pkgObj)
            {
                selectedPackages.Add(pkgObj.Package.Name);
                selectedPackageUpdates.Add(pkgObj.Package);
            }
        }

        if (selectedPackages.Count != _listStore.GetNItems())
        {
            var args = new GenericQuestionEventArgs(
                T("Update Packages?"),
                T("It is unadvised to not update all packages at once. Are you sure you want to continue?")
            );

            genericQuestionService.RaiseQuestion(args);
            if (!await args.ResponseTask)
            {
                return;
            }
        }

        if (selectedPackages.Count != 0)
        {
            if (!configService.LoadConfig().NoConfirm)
            {
                var args = new GenericQuestionEventArgs(
                    T("Update Packages?"),
                    BuildUpdateConfirmationMessage(selectedPackageUpdates),
                    true
                );

                genericQuestionService.RaiseQuestion(args);
                if (!await args.ResponseTask)
                {
                    return;
                }
            }

            var isFullUpgrade = selectedPackages.Count == _listStore.GetNItems();
            try
            {
                OverlayHelper.ShowLoading(_loadingOverlay, _loadingSpinner, _errorLabel);

                lockoutService.Show(T("Updating..."));
                OperationResult upgradeResult;
                if (isFullUpgrade)
                    upgradeResult = await privilegedOperationService.UpgradeSystemAsync();
                else
                    upgradeResult = await privilegedOperationService.UpdatePackagesAsync(selectedPackages);

                await LoadDataAsync(_cts.Token, _loadGeneration);

                if (upgradeResult.NeedsReboot)
                {
                    var rebootArgs = new GenericQuestionEventArgs(
                        T("Reboot Required"),
                        T("A full system reboot is required for updates to take effect.\n\nWould you like to reboot now?"),
                        true
                    );
                    genericQuestionService.RaiseQuestion(rebootArgs);
                    if (await rebootArgs.ResponseTask)
                    {
                        System.Diagnostics.Process.Start("systemctl", "reboot");
                    }
                }
                else if (upgradeResult.FailedServiceRestarts.Count > 0)
                {
                    var failureList = string.Join("\n", upgradeResult.FailedServiceRestarts
                        .Select(f => $"  • {f.Service}: {f.Error}"));
                    var failArgs = new GenericQuestionEventArgs(
                        T("Service Restart Failures"),
                        T("The following services failed to restart automatically:\n{0}", failureList));
                    genericQuestionService.RaiseQuestion(failArgs);
                    await failArgs.ResponseTask;
                }

                if (upgradeResult.Success)
                {
                    var args = new ToastMessageEventArgs(
                        T("Updated {0} Package(s)", selectedPackages.Count)
                    );
                    genericQuestionService.RaiseToastMessage(args);
                }

            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to install packages: {e.Message}");
            }
            finally
            {
                OverlayHelper.HideLoading(_loadingOverlay, _loadingSpinner);
                lockoutService.Hide();
            }
        }
    }

    private static string BuildUpdateConfirmationMessage(IEnumerable<AlpmPackageUpdateDto> selectedPackageUpdates)
    {
        var packages = selectedPackageUpdates.ToList();
        if (packages.Count == 0)
        {
            return string.Empty;
        }

        const int maxPackageColumnWidth = 28;
        var packageColumnWidth = Math.Min(
            maxPackageColumnWidth,
            packages.Max(package => package.Name.Length));

        return string.Join(Environment.NewLine, packages.Select(package =>
            $"{FormatPackageName(package.Name, packageColumnWidth)}  {package.CurrentVersion} -> {package.NewVersion}"));
    }

    private static string FormatPackageName(string packageName, int width)
    {
        if (packageName.Length > width)
        {
            var truncatedWidth = Math.Max(1, width - 1);
            packageName = packageName[..truncatedWidth] + "…";
        }

        return packageName.PadRight(width);
    }

    private bool AnySelected()
    {
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AlpmUpdateGObject { IsSelected: true })
            {
                return true;
            }
        }

        return false;
    }

    public void Dispose()
    {
        _sub?.Dispose();
        _cts.Cancel();
        _cts.Dispose();
        _listStore.RemoveAll();
        _packageGObjectRefs.Clear();
    }
}