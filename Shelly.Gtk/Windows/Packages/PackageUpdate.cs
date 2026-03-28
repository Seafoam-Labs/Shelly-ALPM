using GLib.Internal;
using GObject;
using Gtk;
using Shelly.Gtk.Helpers;
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
    IIconResolverService iconResolverService) : IShellyWindow
{
    private readonly CancellationTokenSource _cts = new();
    private bool _suppressToggleConfirmation;
    private Box _box = null!;
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
    private SignalListItemFactory _oldVersionFactory = null!;
    private SignalListItemFactory _sizeDiffFactory = null!;
    private SignalListItemFactory _versionFactory = null!;
    private readonly List<AlpmUpdateGObject> _packageGObjectRefs = [];

    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _oldColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private ColumnViewColumn _sizeDiffColumn = null!;
    private Button _refreshButton = null!;
    private Button _updateButton = null!;
    private Label _noPackagesLabel = null!;

    private Revealer _detailRevealer = null!;
    private Box _detailBox = null!;
    private AlpmUpdateGObject? _currentDetailPkg;


    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Package/UpdateWindow.ui"), -1);
        _box = (Box)builder.GetObject("UpdateWindow")!;
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
        _noPackagesLabel = (Label)builder.GetObject("no_packages_label")!;
        _noPackagesLabel.Label_ = "<span size='large'>System packages are up to date</span>";
        _noPackagesLabel.Visible = false;
        _detailRevealer = (Revealer)builder.GetObject("detail_revealer")!;
        _detailBox = (Box)builder.GetObject("detail_box")!;
        _listStore = Gio.ListStore.New(AlpmUpdateGObject.GetGType());
        _filter = CustomFilter.New(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _selectionModel.CanUnselect = true;
        _columnView.SetModel(_selectionModel);

        SetupColumns(_checkColumn, _nameColumn, _sizeDiffColumn, _oldColumn, _versionColumn);

        ColumnViewHelper.AlignColumnHeader(_columnView, 1, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 2, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 3, Align.End);

        _columnView.OnRealize += (_, _) => { _ = LoadDataAsync(); };
        _columnView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            if (item is AlpmUpdateGObject pkgObj)
            {
                if (pkgObj.IsSelected)
                {
                    _ = ConfirmPartialUpdateAsync(() => pkgObj.ToggleSelection());
                }
                else
                {
                    pkgObj.ToggleSelection();
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
            if (item is AlpmUpdateGObject pkgObj)
            {
                ShowPackageDetails(pkgObj);
            }
            else
            {
                _detailRevealer.SetRevealChild(false);
                _detailRevealer.SetVisible(false);
                _currentDetailPkg = null;
            }
        };
        _updateButton.OnClicked += (_, _) => { _ = UpdateSelectedAsync(); };
        _refreshButton.OnClicked += (_, _) => { _ = LoadDataAsync(); };

        return _box;
    }

    private void ShowPackageDetails(AlpmUpdateGObject pkgObj)
    {
        if (pkgObj.Package == null) return;

        _currentDetailPkg = pkgObj;
        var pkg = pkgObj.Package;

        while (_detailBox.GetFirstChild() is { } child)
        {
            _detailBox.Remove(child);
        }

        var backButton = Button.New();
        backButton.SetIconName("go-previous-symbolic");
        backButton.Halign = Align.Start;
        backButton.AddCssClass("flat");
        backButton.TooltipText = "Close details";
        backButton.OnClicked += (_, _) =>
        {
            _currentDetailPkg = null;
            _selectionModel.UnselectItem(_selectionModel.GetSelected());
            _detailRevealer.SetRevealChild(false);
            _detailRevealer.SetVisible(false);
        };
        _detailBox.Append(backButton);

        void AddDetail(string label, string value)
        {
            var row = Box.New(Orientation.Horizontal, 4);
            var labelWidget = Label.New(label + ":");
            labelWidget.AddCssClass("dim-label");
            labelWidget.Halign = Align.Start;
            labelWidget.Valign = Align.Start;
            labelWidget.WidthRequest = 70;

            var valueWidget = Label.New(value);
            valueWidget.Halign = Align.Start;
            valueWidget.Wrap = true;
            valueWidget.WrapMode = Pango.WrapMode.WordChar;
            valueWidget.MaxWidthChars = 20;
            valueWidget.Xalign = 0;

            row.Append(labelWidget);
            row.Append(valueWidget);
            _detailBox.Append(row);
        }

        var iconImage = new Image { PixelSize = 64, Halign = Align.Center, MarginBottom = 8 };
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

        _detailBox.Append(iconImage);

        AddDetail("Name", pkg.Name);
        AddDetail("Current", pkg.CurrentVersion);
        AddDetail("New", pkg.NewVersion);
        AddDetail("Download", SizeHelpers.FormatSize(pkg.DownloadSize));
        AddDetail("Size Diff", SizeHelpers.FormatSize(pkg.SizeDifference));

        _detailRevealer.SetVisible(true);
        _detailRevealer.SetRevealChild(true);
    }

    private void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn,
        ColumnViewColumn sizeDiffColumn, ColumnViewColumn oldColumn, ColumnViewColumn versionColumn)
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
            if (listItem.GetItem() is not AlpmUpdateGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;

            checkButton.SetActive(pkgObj.IsSelected);
            checkButton.OnToggled += OnToggled;

            pkgObj.OnSelectionToggled += OnExternalToggle;
            _checkBinding[listItem] = (OnToggled, OnExternalToggle);

            return;

            void OnToggled(CheckButton s, EventArgs e)
            {
                if (_suppressToggleConfirmation)
                {
                    pkgObj.IsSelected = s.GetActive();
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
                    });
                }
                else
                {
                    pkgObj.IsSelected = true;
                }
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
            if (listItem.GetItem() is not AlpmUpdateGObject pkgObj ||
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
            var box = Box.New(Orientation.Horizontal, 6);
            var packageIcon = new Image { PixelSize = 24 };
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
        };
        versionColumn.SetFactory(_versionFactory);
    }

    private bool FilterPackage(GObject.Object obj)
    {
        if (obj is not AlpmUpdateGObject pkgObj || pkgObj.Package == null)
            return false;

        if (string.IsNullOrWhiteSpace(_searchText))
            return true;

        return pkgObj.Package.Name.Contains(_searchText, StringComparison.OrdinalIgnoreCase);
    }

    private async Task LoadDataAsync()
    {
        try
        {
            var packages = await unprivilegedOperationService.CheckForStandardApplicationUpdates();
            GLib.Functions.IdleAdd(0, () =>
            {
                _listStore.RemoveAll();
                _packageGObjectRefs.Clear();
                foreach (var package in packages)
                {
                    var pkgObj = new AlpmUpdateGObject { Package = package };
                    _packageGObjectRefs.Add(pkgObj);
                    _listStore.Append(pkgObj);
                }

                _noPackagesLabel.Visible = packages.Count == 0;
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load packages: {e.Message}");
        }
    }

    private async Task ConfirmPartialUpdateAsync(Action onConfirmed)
    {
        var args = new GenericQuestionEventArgs(
            "Partial Update Warning",
            "It is not advised you do partial system updates. Are you sure you want to continue?"
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
                "Update Packages?",
                "It is unadvised to not update all packages at once. Are you sure you want to continue?"
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
                    "Update Packages?",
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
                lockoutService.Show($"Updating...");
                if (isFullUpgrade)
                    await privilegedOperationService.UpgradeSystemAsync();
                else
                    await privilegedOperationService.UpdatePackagesAsync(selectedPackages);

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
                    $"Updated {selectedPackages.Count} Package(s)"
                );
                genericQuestionService.RaiseToastMessage(args);
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

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
        _listStore.RemoveAll();
        _packageGObjectRefs.Clear();
        _checkBinding.Clear();
    }
}