using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

// ReSharper disable RedundantAssignment

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows;

public class ShellySearch(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService,
    ILockoutService lockoutService) : IShellyWindow
{
    private readonly CancellationTokenSource _cts = new();
    private Box _box = null!;
    private ColumnView _columnView = null!;
    private Gio.ListStore _listStore = null!;
    private SingleSelection _selectionModel = null!;
    private Button _installButton = null!;
    private Button _removeButton = null!;
    private string? _initialQuery;

    private SignalListItemFactory _checkFactory = null!;
    private SignalListItemFactory _nameFactory = null!;
    private SignalListItemFactory _repoFactory = null!;
    private SignalListItemFactory _versionFactory = null!;
    private SignalListItemFactory _descriptionFactory = null!;
    private SignalListItemFactory _lastUpdatedFactory = null!;

    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _repoColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private ColumnViewColumn _descriptionColumn = null!;
    private ColumnViewColumn _lastUpdatedColumn = null!;

    private Dictionary<ColumnViewCell, EventHandler> _checkBinding = [];
    private Dictionary<ColumnViewCell, EventHandler> _installedBinding = [];
    private readonly List<MetaPackageGObject> _packageGObjectRefs = [];

    private Stack _searchStack = null!;
    private Spinner _searchSpinner = null!;
    private SearchEntry _searchEntry = null!;

    public Widget CreateWindow() => CreateWindow(null);

    public Widget CreateWindow(string? initialQuery)
    {
        _initialQuery = initialQuery;
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/ShellySearchWindow.ui"), -1);

        _box = (Box)builder.GetObject("ShellySearchWindow")!;
        _columnView = (ColumnView)builder.GetObject("package_grid")!;
        _installButton = (Button)builder.GetObject("install_button")!;
        _installButton.SetSensitive(false);
        _removeButton = (Button)builder.GetObject("remove_button")!;
        _removeButton.SetSensitive(false);

        _checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        _nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        _repoColumn = (ColumnViewColumn)builder.GetObject("repo_column")!;
        _versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        _descriptionColumn = (ColumnViewColumn)builder.GetObject("description_column")!;
        _lastUpdatedColumn = (ColumnViewColumn)builder.GetObject("last_updated_column")!;
        _searchEntry = (SearchEntry)builder.GetObject("search_entry")!;

        if (!string.IsNullOrEmpty(_initialQuery))
            _searchEntry.SetText(_initialQuery);

        _searchEntry.OnActivate += (_, _) =>
        {
            _initialQuery = _searchEntry.GetText();
            _ = LoadDataAsync();
        };

        _listStore = Gio.ListStore.New(MetaPackageGObject.GetGType());
        _selectionModel = SingleSelection.New(_listStore);
        _selectionModel.CanUnselect = true;
        _columnView.SetModel(_selectionModel);

        SetupColumns(_checkColumn, _nameColumn, _repoColumn, _versionColumn, _descriptionColumn, _lastUpdatedColumn);

        ColumnViewHelper.AlignColumnHeader(_columnView, 2, Align.Start);
        ColumnViewHelper.AlignColumnHeader(_columnView, 3, Align.End);

        _installButton.OnClicked += (_, _) => { _ = InstallSelectedAsync(); };
        _removeButton.OnClicked += (_, _) => { _ = RemoveSelectedAsync(); };

        // Create spinner/stack for loading state
        var spinnerBox = Box.New(Orientation.Vertical, 10);
        spinnerBox.SetValign(Align.Center);
        spinnerBox.SetHalign(Align.Center);
        spinnerBox.SetVexpand(true);
        _searchSpinner = Spinner.New();
        _searchSpinner.SetSizeRequest(48, 48);
        var searchingLabel = Label.New("Searching...");
        spinnerBox.Append(_searchSpinner);
        spinnerBox.Append(searchingLabel);

        _searchStack = Stack.New();
        _searchStack.SetVexpand(true);
        _searchStack.AddNamed(spinnerBox, "loading");

        // Move the ScrolledWindow (parent of _columnView) into the stack
        var scrolledWindow = _columnView.GetParent()!;
        _box.Remove(scrolledWindow);
        _searchStack.AddNamed(scrolledWindow, "results");
        _box.Append(_searchStack);

        _searchStack.SetVisibleChildName("results");

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
        ColumnViewColumn versionColumn, ColumnViewColumn descriptionColumn, ColumnViewColumn lastUpdatedColumn)
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
                if (listItem.GetItem() is MetaPackageGObject pkgObj)
                    pkgObj.IsSelected = s.GetActive();
                UpdateButtonSensitivity();
            };
        };
        _checkFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
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
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not MetaPackageGObject pkgObj) return;
            if (_checkBinding.Remove(listItem, out var handler)) pkgObj.OnSelectionToggled -= handler;
        };
        checkColumn.SetFactory(_checkFactory);

        _nameFactory = SignalListItemFactory.New();
        _nameFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var box = Box.New(Orientation.Horizontal, 6);
            var label = Label.New(null);
            label.Halign = Align.Start;
            label.MarginStart = 6;
            label.Ellipsize = Pango.EllipsizeMode.End;
            label.Xalign = 0;
            var installedIcon = Image.NewFromIconName("object-select-symbolic");
            box.Append(label);
            box.Append(installedIcon);
            listItem.SetChild(box);
        };
        _nameFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not MetaPackageGObject { Package: { } pkg } pkgObj ||
                listItem.GetChild() is not Box box) return;
            var label = (Label)box.GetFirstChild()!;
            var installedIcon = (Image)label.GetNextSibling()!;
            label.SetText(pkg.Name);
            installedIcon.Visible = pkg.IsInstalled;
            installedIcon.TooltipText = "Installed";

            pkgObj.OnIsInstalledChanged += OnInstalledChanged;
            _installedBinding[listItem] = OnInstalledChanged;
            return;

            void OnInstalledChanged(object? sender, EventArgs e)
            {
                installedIcon.Visible = pkgObj.IsInstalled;
            }
        };
        _nameFactory.OnUnbind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not MetaPackageGObject pkgObj) return;
            if (_installedBinding.Remove(listItem, out var handler)) pkgObj.OnIsInstalledChanged -= handler;
        };
        nameColumn.SetFactory(_nameFactory);

        _repoFactory = SignalListItemFactory.New();
        _repoFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(null);
            label.Halign = Align.End;
            label.MarginStart = 6;
            //label.Wrap = true;
            //label.WrapMode = Pango.WrapMode.WordChar;
            listItem.SetChild(label);
        };
        _repoFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(pkg.Repository);
        };
        repoColumn.SetFactory(_repoFactory);

        _versionFactory = SignalListItemFactory.New();
        _versionFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(null);
            label.Halign = Align.End;
            label.MarginStart = 6;
            label.Ellipsize = Pango.EllipsizeMode.End;
            label.Xalign = 1;
            listItem.SetChild(label);
        };
        _versionFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(pkg.Version);
        };
        versionColumn.SetFactory(_versionFactory);

        _descriptionFactory = SignalListItemFactory.New();
        _descriptionFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(null);
            label.Halign = Align.Fill;
            label.Hexpand = true;
            label.MarginStart = 6;
            label.Wrap = true;
            label.WrapMode = Pango.WrapMode.WordChar;
            label.NaturalWrapMode = NaturalWrapMode.Word;
            label.MaxWidthChars = 1;
            label.WidthChars = 0;
            label.Xalign = 0;
            label.WidthRequest = 1;
            listItem.SetChild(label);
        };
        _descriptionFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(pkg.Description);
        };
        descriptionColumn.SetFactory(_descriptionFactory);

        _lastUpdatedFactory = SignalListItemFactory.New();
        _lastUpdatedFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(null);
            label.Halign = Align.Fill;
            label.Hexpand = true;
            label.MarginStart = 6;
            label.Wrap = true;
            label.WrapMode = Pango.WrapMode.WordChar;
            label.NaturalWrapMode = NaturalWrapMode.Word;
            label.MaxWidthChars = 1;
            label.WidthChars = 0;
            label.Xalign = 0;
            label.WidthRequest = 1;
            listItem.SetChild(label);
        };
        _lastUpdatedFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(DateTimeOffset.FromUnixTimeSeconds(pkg.LastUpdated).ToString("yyyy-MM-dd HH:mm"));
        };
        lastUpdatedColumn.SetFactory(_lastUpdatedFactory);
    }

    private async Task LoadDataAsync()
    {
        Console.WriteLine(_initialQuery);
        if (string.IsNullOrWhiteSpace(_initialQuery))
        {
            _listStore.RemoveAll();
            return;
        }

        GLib.Functions.IdleAdd(0, () =>
        {
            _searchSpinner.Start();
            _searchStack.SetVisibleChildName("loading");
            return false;
        });

        try
        {
            List<Task<List<MetaPackageModel>>> groupList = [];

            var standardTask = Task.Run(async () =>
            {
                var standardInstalled = await privilegedOperationService.GetInstalledPackagesAsync().ContinueWith(x =>
                    x.Result.Select(y => new MetaPackageModel(
                        y.Name,
                        y.Name,
                        y.Version,
                        y.Description,
                        PackageType.Standard,
                        y.Description,
                        y.Repository,
                        true,
                        new DateTimeOffset(y.BuildDate).ToUnixTimeSeconds()
                    )).ToList());
                var standardAvailable = await privilegedOperationService.SearchPackagesAsync(_initialQuery)
                    .ContinueWith(x =>
                        x.Result.Select(y => new MetaPackageModel(
                            y.Name,
                            y.Name,
                            y.Version,
                            y.Description,
                            PackageType.Standard,
                            y.Description,
                            y.Repository,
                            standardInstalled.Any(z => z.Name == y.Name),
                            new DateTimeOffset(y.BuildDate).ToUnixTimeSeconds()
                        )).ToList());
                return standardAvailable;
            });
            groupList.Add(standardTask);

            if (configService.LoadConfig().FlatPackEnabled)
            {
                var flatpakGroup = Task.Run(async () =>
                {
                    // Sync appstream cache (with timeout so it doesn't block forever)
                    var syncTask = unprivilegedOperationService.FlatpakSyncRemoteAppstream();
                    await Task.WhenAny(syncTask, Task.Delay(TimeSpan.FromSeconds(5), _cts.Token));

                    // Get installed list for marking installed status
                    var flatPakInstalled = await unprivilegedOperationService.ListFlatpakPackages().ContinueWith(x =>
                        x.Result.Select(y => y.Id).ToHashSet());

                    // Load all appstream apps and filter by query
                    var allApps = await unprivilegedOperationService.ListAppstreamFlatpak(_cts.Token);
                    var query = _initialQuery!;
                    var filtered = allApps
                        .Where(app => app.Type != "addon")
                        .Where(app =>
                            app.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                            app.Description.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                            app.Id.Contains(query, StringComparison.OrdinalIgnoreCase))
                        .Take(100)
                        .Select(app => new MetaPackageModel(
                            app.Id,
                            app.Name,
                            app.Releases.FirstOrDefault()?.Version ?? string.Empty,
                            app.Description,
                            PackageType.Flatpak,
                            app.Summary,
                            app.Remotes.FirstOrDefault()?.Name ?? "Flatpak",
                            flatPakInstalled.Contains(app.Id),
                            app.Releases.FirstOrDefault()?.Timestamp ?? DateTimeOffset.MinValue.ToUnixTimeSeconds()
                        )).ToList();

                    return filtered;
                });
                groupList.Add(flatpakGroup);
            }

            if (configService.LoadConfig().AurEnabled)
            {
                var aurGroup = Task.Run(async () =>
                {
                    var aurInstalled = await privilegedOperationService.GetAurInstalledPackagesAsync()
                        .ContinueWith(x =>
                            x.Result.Select(y => new MetaPackageModel(
                                y.Name,
                                y.Name,
                                y.Version,
                                y.Description ?? "",
                                PackageType.Aur,
                                y.Url ?? "",
                                "AUR",
                                true,
                                y.LastModified)
                            ).ToList());
                    var aurAvailable = await privilegedOperationService.SearchAurPackagesAsync(_initialQuery)
                        .ContinueWith(x => x.Result.Select(y => new MetaPackageModel(
                            y.Name,
                            y.Name,
                            y.Version,
                            y.Description ?? "",
                            PackageType.Aur,
                            y.Url ?? "",
                            "AUR",
                            aurInstalled.Any(z => z.Name == y.Name),
                            y.LastModified)
                        ).ToList());
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
                _packageGObjectRefs.Clear();
                foreach (var pkgObj in models.Select(model =>
                         {
                             var o = MetaPackageGObject.NewWithProperties([]);
                             o.Package = model;
                             return o;
                         }))
                {
                    _packageGObjectRefs.Add(pkgObj);
                    _listStore.Append(pkgObj);
                }

                return false;
            });
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Search error: {ex.Message}");
        }
        finally
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                _searchSpinner.Stop();
                _searchStack.SetVisibleChildName("results");
                return false;
            });
        }
    }

    private async Task InstallSelectedAsync()
    {
        _installButton.SetSensitive(false);
        _removeButton.SetSensitive(false);

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

        bool installFailed = false;

        try
        {
            lockoutService.Show($"Installing...");
            var standard = selected.Where(x => x.PackageType == PackageType.Standard).Select(x => x.Name).ToList();
            var aur = selected.Where(x => x.PackageType == PackageType.Aur).Select(x => x.Name).ToList();
            var flatpak = selected.Where(x => x.PackageType == PackageType.Flatpak).Select(x => x.Id).ToList();

            if (standard.Count > 0)
            {
                var optResult = await privilegedOperationService.InstallPackagesAsync(standard);
                installFailed = !optResult.Success;
            }

            if (aur.Count > 0)
            {
                var optResult = await privilegedOperationService.InstallAurPackagesAsync(aur);
                installFailed = !optResult.Success;
            }

            if (flatpak.Count > 0)
            {
                foreach (var pkg in selected.Where(x => x.PackageType == PackageType.Flatpak))
                {
                    var optResult =
                        await unprivilegedOperationService.InstallFlatpakPackage(pkg.Id, false, pkg.Repository,
                            "stable");
                    installFailed = !optResult.Success;
                }
            }

            for (uint i = 0; i < _listStore.GetNItems(); i++)
            {
                if (_listStore.GetObject(i) is not MetaPackageGObject { IsSelected: true } pkgObj) continue;
                pkgObj.IsInstalled = true;
                pkgObj.IsSelected = false;
                pkgObj.NotifySelectionChanged();
            }
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to install packages: {e.Message}");
        }
        finally
        {
            lockoutService.Hide();
            ToastMessageEventArgs args;
            if (installFailed)
            {
                args = new ToastMessageEventArgs(
                    $"Install for {selected.Count} package(s) was unsuccessful."
                );
            }
            else
            {
                args = new ToastMessageEventArgs(
                    $"Installed {selected.Count} Package(s)"
                );
            }

            genericQuestionService.RaiseToastMessage(args);

            UpdateButtonSensitivity();
        }
    }

    private void UpdateButtonSensitivity()
    {
        var anyInstalledSelected = false;
        var anyNotInstalledSelected = false;
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is not MetaPackageGObject { IsSelected: true, Package: not null } pkgObj) continue;
            if (pkgObj.Package.IsInstalled)
                anyInstalledSelected = true;
            else
                anyNotInstalledSelected = true;
        }

        _installButton.SetSensitive(anyNotInstalledSelected);
        _removeButton.SetSensitive(anyInstalledSelected);
    }

    private async Task RemoveSelectedAsync()
    {
        _removeButton.SetSensitive(false);
        _installButton.SetSensitive(false);

        var selected = new List<MetaPackageModel>();
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is MetaPackageGObject { IsSelected: true, Package: { IsInstalled: true } } pkgObj)
            {
                selected.Add(pkgObj.Package);
            }
        }

        if (selected.Count == 0) return;

        try
        {
            lockoutService.Show("Removing...");

            var standard = selected.Where(x => x.PackageType == PackageType.Standard).Select(x => x.Name).ToList();
            var aur = selected.Where(x => x.PackageType == PackageType.Aur).Select(x => x.Name).ToList();
            var flatpak = selected.Where(x => x.PackageType == PackageType.Flatpak).Select(x => x.Id).ToList();

            if (standard.Count > 0) await privilegedOperationService.RemovePackagesAsync(standard, false, false);
            if (aur.Count > 0) await privilegedOperationService.RemoveAurPackagesAsync(aur);
            if (flatpak.Count > 0) await unprivilegedOperationService.RemoveFlatpakPackage(flatpak);

            for (uint i = 0; i < _listStore.GetNItems(); i++)
            {
                if (_listStore.GetObject(i) is not MetaPackageGObject { IsSelected: true } pkgObj) continue;
                pkgObj.IsInstalled = false;
                pkgObj.IsSelected = false;
                pkgObj.NotifySelectionChanged();
            }
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to remove packages: {e.Message}");
        }
        finally
        {
            lockoutService.Hide();

            var args = new ToastMessageEventArgs(
                $"Removed {selected.Count} Package(s)"
            );
            genericQuestionService.RaiseToastMessage(args);

            UpdateButtonSensitivity();
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
        _listStore.RemoveAll();
        _packageGObjectRefs.Clear();
        _checkBinding.Clear();
        _installedBinding.Clear();
    }
}