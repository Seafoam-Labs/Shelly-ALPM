using GObject;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.Packages;

public class PackageInstall(
    IPrivilegedOperationService privilegedOperationService,
    ILockoutService lockoutService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService)
    : IShellyWindow
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
    private List<string> _groups = [];

    private Dictionary<ColumnViewCell, (SignalHandler<CheckButton> OnToggled, EventHandler OnExternalToggle)>
        _checkBinding =
            [];

    private SignalListItemFactory _checkFactory = null!;
    private SignalListItemFactory _nameFactory = null!;
    private SignalListItemFactory _sizeFactory = null!;
    private SignalListItemFactory _versionFactory = null!;
    private SignalListItemFactory _repositoryFactory = null!;
    private readonly List<AlpmPackageGObject> _packageGObjectRefs = [];

    private Button _installButton = null!;
    private Button _localInstallButton = null!;
    private Button _appImageButton = null!;
    private SearchEntry _searchEntry = null!;
    private Builder _builder = null!;
    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _sizeColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private ColumnViewColumn _repositoryColumn = null!;
    private DropDown _groupDropDown = null!;

    private Revealer _detailRevealer = null!;
    private Box _detailBox = null!;
    private AlpmPackageGObject? _currentDetailPkg;

    public Widget CreateWindow()
    {
        _builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Package/PackageWindow.ui"), -1);
        _overlay = (Overlay)_builder.GetObject("PackageWindow")!;
        _columnView = (ColumnView)_builder.GetObject("package_column_view")!;
        _checkColumn = (ColumnViewColumn)_builder.GetObject("check_column")!;
        _nameColumn = (ColumnViewColumn)_builder.GetObject("name_column")!;
        _sizeColumn = (ColumnViewColumn)_builder.GetObject("size_column")!;
        _versionColumn = (ColumnViewColumn)_builder.GetObject("version_column")!;
        _repositoryColumn = (ColumnViewColumn)_builder.GetObject("repository_column")!;
        _installButton = (Button)_builder.GetObject("install_button")!;
        _localInstallButton = (Button)_builder.GetObject("install_local_button")!;
        _appImageButton = (Button)_builder.GetObject("install_appimage_button")!;
        _searchEntry = (SearchEntry)_builder.GetObject("search_entry")!;
        _detailRevealer = (Revealer)_builder.GetObject("detail_revealer")!;
        _detailBox = (Box)_builder.GetObject("detail_box")!;

        _listStore = Gio.ListStore.New(AlpmPackageGObject.GetGType());
        _filter = CustomFilter.New(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _selectionModel.CanUnselect = true;
        _columnView.SetModel(_selectionModel);

        SetupColumns(_checkColumn, _nameColumn, _sizeColumn, _versionColumn, _repositoryColumn);

        ColumnViewHelper.AlignColumnHeader(_columnView, 1, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 2, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 3, Align.End);

        _columnView.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };
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
        _localInstallButton.OnClicked += (_, _) => { _ = InstallLocalPackage(); };
        _appImageButton.OnClicked += (_, _) => { _ = InstallAppImage(); };

        return _overlay;
    }

    private void ShowPackageDetails(AlpmPackageGObject pkgObj)
    {
        if (pkgObj.Package == null) return;

        _currentDetailPkg = pkgObj;
        var pkg = pkgObj.Package;

        while (_detailBox.GetFirstChild() is { } child)
        {
            _detailBox.Remove(child);
        }

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
            //valueWidget.Hexpand = true;
            valueWidget.MaxWidthChars = 20;
            valueWidget.Xalign = 0;

            row.Append(labelWidget);
            row.Append(valueWidget);
            _detailBox.Append(row);
        }

        AddDetail("Name", pkg.Name);
        AddDetail("Description", pkg.Description);
        AddDetail("Version", pkg.Version);
        AddDetail("Repository", pkg.Repository);
        AddDetail("Size", SizeHelpers.FormatSize(pkg.InstalledSize));
        if (!string.IsNullOrEmpty(pkg.Url))
        {
            var row = Box.New(Orientation.Horizontal, 4);
            var labelWidget = Label.New("URL:");
            labelWidget.AddCssClass("dim-label");
            labelWidget.Halign = Align.Start;
            labelWidget.Valign = Align.Start;
            labelWidget.WidthRequest = 70;

            var valueWidget = Label.New(null);
            var escaped = GLib.Functions.MarkupEscapeText(pkg.Url, -1);
            valueWidget.SetMarkup($"<a href=\"{escaped}\">{escaped}</a>");
            valueWidget.Halign = Align.Start;
            valueWidget.Wrap = true;
            valueWidget.WrapMode = Pango.WrapMode.WordChar;
            valueWidget.MaxWidthChars = 20;
            valueWidget.Xalign = 0;

            row.Append(labelWidget);
            row.Append(valueWidget);
            _detailBox.Append(row);
        }

        if (pkg.Depends.Count > 0)
            AddDetail("Depends", string.Join(", ", pkg.Depends));
        if (pkg.OptDepends.Count > 0)
            AddDetail("Optional Deps", string.Join(", ", pkg.OptDepends));
        if (pkg.Licenses.Count > 0)
            AddDetail("Licenses", string.Join(", ", pkg.Licenses));
        if (pkg.Provides.Count > 0)
            AddDetail("Provides", string.Join(", ", pkg.Provides));
        if (pkg.Conflicts.Count > 0)
            AddDetail("Conflicts", string.Join(", ", pkg.Conflicts));
        if (pkg.Groups.Count > 0)
            AddDetail("Groups", string.Join(", ", pkg.Groups));

        _detailRevealer.SetRevealChild(true);
    }

    private void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn,
        ColumnViewColumn sizeColumn, ColumnViewColumn versionColumn, ColumnViewColumn repositoryColumn)
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
            var box = Box.New(Orientation.Horizontal, 6);
            var label = Label.New(string.Empty);
            var installedIcon = Image.NewFromIconName("object-select-symbolic");

            box.Append(label);
            box.Append(installedIcon);
            listItem.SetChild(box);
        };
        _nameFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject { Package: { } pkg } pkgObj ||
                listItem.GetChild() is not Box box) return;

            var label = (Label)box.GetFirstChild()!;
            var installedIcon = (Image)label.GetNextSibling()!;

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

        _repositoryFactory = new SignalListItemFactory();
        _repositoryFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };

        _repositoryFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AlpmPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Repository);
            label.Halign = Align.End;
        };
        repositoryColumn.SetFactory(_repositoryFactory);
    }

    private async Task LoadDataAsync(CancellationToken ct = default)
    {
        _listStore.RemoveAll();
        _packageGObjectRefs.Clear();
        _detailRevealer.SetRevealChild(false);
        _currentDetailPkg = null;
        try
        {
            _packages = await privilegedOperationService.GetAvailablePackagesAsync();
            var installedPackages = await privilegedOperationService.GetInstalledPackagesAsync();
            var installedNames = new HashSet<string>(installedPackages?.Select(x => x.Name) ?? []);

            ct.ThrowIfCancellationRequested();
            var queue = new Queue<AlpmPackageDto>(_packages);

            GLib.Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested)
                {
                    return false;
                }

                const int batchSize = 1000;
                var count = 0;
                var batch = new List<AlpmPackageGObject>();
                while (queue.Count > 0 && count < batchSize)
                {
                    var dequeued = queue.Dequeue();
                    var pkgObj = new AlpmPackageGObject()
                        { Package = dequeued, IsInstalled = installedNames.Contains(dequeued.Name) };
                    _packageGObjectRefs.Add(pkgObj);
                    batch.Add(pkgObj);
                    count++;
                }

                // ReSharper disable once CoVariantArrayConversion
                _listStore.Splice(_listStore.GetNItems(), 0, batch.ToArray(), (uint)batch.Count);

                return queue.Count > 0;
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
        if (obj is AlpmPackageGObject pkgObj && pkgObj.Package != null)
        {
            if (string.IsNullOrWhiteSpace(_searchText))
                return true;

            return pkgObj.Package.Name.Contains(_searchText, StringComparison.OrdinalIgnoreCase) ||
                   pkgObj.Package.Description.Contains(_searchText, StringComparison.OrdinalIgnoreCase);
        }

        return false;
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
                if (!configService.LoadConfig().NoConfirm)
                {
                    var args = new GenericQuestionEventArgs(
                        "Install Packages?", string.Join("\n", selectedPackages)
                    );

                    genericQuestionService.RaiseQuestion(args);
                    if (!await args.ResponseTask)
                    {
                        return;
                    }
                }

                lockoutService.Show($"Installing...");
                await privilegedOperationService.InstallPackagesAsync(selectedPackages);
                await LoadDataAsync();
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
        }
    }

    private async Task InstallAppImage()
    {
        try
        {
            var dialog = FileDialog.New();
            dialog.SetTitle("Install App Image");

            var filter = FileFilter.New();
            filter.SetName("Local AppImage files (\"*.AppImage\"");
            filter.AddPattern("*.AppImage");

            var filters = Gio.ListStore.New(FileFilter.GetGType());
            filters.Append(filter);
            dialog.SetFilters(filters);

            var file = await dialog.OpenAsync((Window)_overlay.GetRoot()!);

            if (file is not null)
            {
                lockoutService.Show($"Installing AppImage...");
                var result = await privilegedOperationService.InstallAppImageAsync(file.GetPath()!);
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
        }
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