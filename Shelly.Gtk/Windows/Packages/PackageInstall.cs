using GObject;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.Icons;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;
using Shelly.Gtk.Windows.Dialog;

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.Packages;

public class PackageInstall(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    ILockoutService lockoutService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService,
    IIconResolverService iconResolverService)
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
    private StringList _groupsStringList = null!;
    private string _selectedGroup = "Any";

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
    private CheckButton _upgradeCheck = null!;

    private Revealer _detailRevealer = null!;
    private Box _detailBox = null!;
    private AlpmPackageGObject? _currentDetailPkg;

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
        _appImageButton = (Button)_builder.GetObject("install_appimage_button")!;
        _searchEntry = (SearchEntry)_builder.GetObject("search_entry")!;
        _detailRevealer = (Revealer)_builder.GetObject("detail_revealer")!;
        _detailBox = (Box)_builder.GetObject("detail_box")!;
        _groupDropDown = (DropDown)_builder.GetObject("grouping_selection")!;
        _upgradeCheck = (CheckButton)_builder.GetObject("upgrade_check")!;

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
                _detailRevealer.SetVisible(false);
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
            //valueWidget.Hexpand = true;
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
        {
            var expander = new Expander { Label = $"Depends ({pkg.Depends.Count})" };
            expander.AddCssClass("dim-label");
            var depBox = Box.New(Orientation.Vertical, 2);
            depBox.MarginStart = 12;
            foreach (var depLabel in pkg.Depends.Select(dep => Label.New(dep)))
            {
                depLabel.Halign = Align.Start;
                depLabel.Xalign = 0;
                depBox.Append(depLabel);
            }

            expander.SetChild(depBox);
            _detailBox.Append(expander);
        }

        if (pkg.OptDepends.Count > 0)
        {
            var optExpander = new Expander { Label = $"Optional Deps ({pkg.OptDepends.Count})" };
            optExpander.AddCssClass("dim-label");
            var optDepBox = Box.New(Orientation.Vertical, 2);
            optDepBox.MarginStart = 12;
            foreach (var depLabel in pkg.OptDepends.Select(dep => Label.New(dep)))
            {
                depLabel.Halign = Align.Start;
                depLabel.Xalign = 0;
                optDepBox.Append(depLabel);
            }

            optExpander.SetChild(optDepBox);
            _detailBox.Append(optExpander);
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
                        if (obj is not AlpmPackageGObject depObj || depObj.Package == null) continue;
                        if (depObj.Package.Name.Contains(dep))
                            dictionary.TryAdd(depObj.Package.Name, depObj.Package.Depends);
                    }
                }

                var window = new WebWindow(pkg.Name, dictionary);
                _detailBox.Append(window.CreateWindow());
            }
        }

        _detailRevealer.SetVisible(true);
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
                _installButton.SetSensitive(AnySelected());
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
            var packageIcon = new Image { PixelSize = 24 };
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
            if (listItem.GetItem() is not AlpmPackageGObject { Package: { } pkg } pkgObj ||
                listItem.GetChild() is not Box box) return;

            var packageIcon = (Image)box.GetFirstChild()!;
            var label = (Label)packageIcon.GetNextSibling()!;
            var installedIcon = (Image)label.GetNextSibling()!;

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
            _groups = _packages.SelectMany(x => x.Groups).Distinct().ToList();
            _groups.Insert(0, "Any");
            _groupsStringList = StringList.New(_groups.ToArray());
            _groupDropDown.SetModel(_groupsStringList);
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
        if (string.IsNullOrWhiteSpace(_searchText))
            return true;

        if (obj is not AlpmPackageGObject pkgObj || pkgObj.Package == null) return false;

        if (_selectedGroup != "Any" && !pkgObj.Package.Groups.Contains(_selectedGroup))
        {
            return false;
        }

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
                else
                {
                    var args = new ToastMessageEventArgs(
                        $"App Image installed"
                    );

                    genericQuestionService.RaiseToastMessage(args);
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
        _currentDetailPkg = null;
    }
}