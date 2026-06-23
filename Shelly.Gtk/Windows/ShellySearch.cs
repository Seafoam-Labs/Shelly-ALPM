using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;
using static Shelly.GTK.Resources.Translations;

// ReSharper disable RedundantAssignment

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows;

public sealed class ShellySearch(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService,
    ILockoutService lockoutService) : IShellyWindow
{
    private readonly CancellationTokenSource _cts = new();
    private Gio.ListStore _listStore = null!;
    private SingleSelection _selectionModel = null!;
    private Button _installButton = null!;
    private Button _removeButton = null!;
    private string? _initialQuery;
    private readonly bool _deletePackageCache = configService.LoadConfig().RemoveCache;


    private readonly Dictionary<ColumnViewCell, EventHandler> _checkBinding = [];
    private readonly Dictionary<ColumnViewCell, EventHandler> _installedBinding = [];

    private const int MatchScore = 1;
    private Stack _searchStack = null!;
    private Spinner _searchSpinner = null!;
    private SearchEntry _searchEntry = null!;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/ShellySearchWindow.ui"), -1);
        builder.TranslationDomain = Domain;
        var box = (Box)builder.GetObject("ShellySearchWindow")!;
        var columnView = (ColumnView)builder.GetObject("package_grid")!;
        _installButton = (Button)builder.GetObject("install_button")!;
        _installButton.SetSensitive(false);
        _removeButton = (Button)builder.GetObject("remove_button")!;
        _removeButton.SetSensitive(false);

        var checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        var nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        nameColumn.SetSorter(CustomSorter.New<MetaPackageGObject>((a, b) =>
            string.Compare(a.Package?.Name, b.Package?.Name, StringComparison.OrdinalIgnoreCase)));
        var repoColumn = (ColumnViewColumn)builder.GetObject("repo_column")!;
        repoColumn.SetSorter(CustomSorter.New<MetaPackageGObject>((a, b) =>
            string.Compare(a.Package?.Repository, b.Package?.Repository, StringComparison.OrdinalIgnoreCase)));
        var versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        versionColumn.SetSorter(CustomSorter.New<MetaPackageGObject>((a, b) =>
            string.Compare(a.Package?.Version, b.Package?.Version, StringComparison.OrdinalIgnoreCase)));
        var descriptionColumn = (ColumnViewColumn)builder.GetObject("description_column")!;
        var lastUpdatedColumn = (ColumnViewColumn)builder.GetObject("last_updated_column")!;
        lastUpdatedColumn.SetSorter(CustomSorter.New<MetaPackageGObject>((a, b) =>
            a.Package == null || b.Package == null ? 0 : a.Package.LastUpdated.CompareTo(b.Package.LastUpdated)));
        _searchEntry = (SearchEntry)builder.GetObject("search_entry")!;

        if (!string.IsNullOrEmpty(_initialQuery))
            _searchEntry.SetText(_initialQuery);

        _searchEntry.OnActivate += (_, _) =>
        {
            _initialQuery = _searchEntry.GetText();
            _ = LoadDataAsync();
        };

        _listStore = Gio.ListStore.New(MetaPackageGObject.GetGType());
        _selectionModel = SingleSelection.New(
            SortListModel.New(_listStore, columnView.GetSorter()));
        _selectionModel.CanUnselect = true;
        columnView.SetModel(_selectionModel);

        SetupColumns(checkColumn, nameColumn, repoColumn, versionColumn, descriptionColumn, lastUpdatedColumn);

        ColumnViewHelper.AlignColumnHeader(columnView, 2, Align.Start);
        ColumnViewHelper.AlignColumnHeader(columnView, 3, Align.End);

        _installButton.OnClicked += (_, _) => { _ = InstallSelectedAsync(); };
        _removeButton.OnClicked += (_, _) => { _ = RemoveSelectedAsync(); };

        // Create spinner/stack for loading state
        var spinnerBox = Box.New(Orientation.Vertical, 10);
        spinnerBox.SetValign(Align.Center);
        spinnerBox.SetHalign(Align.Center);
        spinnerBox.SetVexpand(true);
        _searchSpinner = Spinner.New();
        _searchSpinner.SetSizeRequest(48, 48);
        var searchingLabel = Label.New(T("Searching..."));
        spinnerBox.Append(_searchSpinner);
        spinnerBox.Append(searchingLabel);

        _searchStack = Stack.New();
        _searchStack.SetVexpand(true);
        _searchStack.AddNamed(spinnerBox, "loading");

        // Move the ScrolledWindow (parent of _columnView) into the stack
        var scrolledWindow = columnView.GetParent()!;
        box.Remove(scrolledWindow);
        _searchStack.AddNamed(scrolledWindow, "results");
        box.Append(_searchStack);

        _searchStack.SetVisibleChildName("results");

        if (!string.IsNullOrEmpty(_initialQuery))
        {
            _ = LoadDataAsync();
        }

        columnView.OnActivate += (_, _) =>
        {
            if (_selectionModel.GetSelectedItem() is MetaPackageGObject pkgObj)
            {
                pkgObj.ToggleSelection();
            }
        };

        return box;
    }

    private void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn, ColumnViewColumn repoColumn,
        ColumnViewColumn versionColumn, ColumnViewColumn descriptionColumn, ColumnViewColumn lastUpdatedColumn)
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
                if (listItem.GetItem() is MetaPackageGObject pkgObj)
                    pkgObj.IsSelected = s.GetActive();
                UpdateButtonSensitivity();
            };
        };
        checkFactory.OnBind += (_, args) =>
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
        checkFactory.OnUnbind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not MetaPackageGObject pkgObj) return;
            if (_checkBinding.Remove(listItem, out var handler)) pkgObj.OnSelectionToggled -= handler;
        };
        checkColumn.SetFactory(checkFactory);

        var nameFactory = SignalListItemFactory.New();
        nameFactory.OnSetup += (_, args) =>
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
        nameFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not MetaPackageGObject { Package: { } pkg } pkgObj ||
                listItem.GetChild() is not Box box) return;
            var label = (Label)box.GetFirstChild()!;
            var installedIcon = (Image)label.GetNextSibling()!;
            label.SetText(pkg.Name);
            installedIcon.Visible = pkg.IsInstalled;
            installedIcon.TooltipText = T("Installed");

            pkgObj.OnIsInstalledChanged += OnInstalledChanged;
            _installedBinding[listItem] = OnInstalledChanged;
            return;

            void OnInstalledChanged(object? sender, EventArgs e)
            {
                installedIcon.Visible = pkgObj.IsInstalled;
            }
        };
        nameFactory.OnUnbind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not MetaPackageGObject pkgObj) return;
            if (_installedBinding.Remove(listItem, out var handler)) pkgObj.OnIsInstalledChanged -= handler;
        };
        nameColumn.SetFactory(nameFactory);

        var repoFactory = SignalListItemFactory.New();
        repoFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(null);
            label.Halign = Align.End;
            label.MarginStart = 6;
            listItem.SetChild(label);
        };
        repoFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(pkg.Repository);
        };
        repoColumn.SetFactory(repoFactory);

        var versionFactory = SignalListItemFactory.New();
        versionFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(null);
            label.Halign = Align.End;
            label.MarginStart = 6;
            label.Ellipsize = Pango.EllipsizeMode.End;
            label.Xalign = 1;
            listItem.SetChild(label);
        };
        versionFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(pkg.Version);
        };
        versionColumn.SetFactory(versionFactory);

        var descriptionFactory = SignalListItemFactory.New();
        descriptionFactory.OnSetup += (_, args) =>
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
        descriptionFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(pkg.Summary);
        };
        descriptionColumn.SetFactory(descriptionFactory);

        var lastUpdatedFactory = SignalListItemFactory.New();
        lastUpdatedFactory.OnSetup += (_, args) =>
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
        lastUpdatedFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is MetaPackageGObject { Package: { } pkg } && listItem.GetChild() is Label label)
                label.SetText(DateTimeOffset.FromUnixTimeSeconds(pkg.LastUpdated).ToString("yyyy-MM-dd HH:mm"));
        };
        lastUpdatedColumn.SetFactory(lastUpdatedFactory);
    }

    private async Task LoadDataAsync()
    {
        var query = _initialQuery;

        if (string.IsNullOrWhiteSpace(query))
        {
            _listStore.RemoveAll();
            return;
        }

        SetLoadingState(true);

        try
        {
            var ct = _cts.Token;
            List<Task<List<MetaPackageModel>>> tasks = [LoadStandardPackagesAsync(query)];

            var config = configService.LoadConfig();
            if (config.FlatPackEnabled)
                tasks.Add(LoadFlatpakPackagesAsync(query, ct));
            if (config.AurEnabled)
                tasks.Add(LoadAurPackagesAsync(query));

            List<MetaPackageModel> models = [];
            await foreach (var task in Task.WhenEach(tasks).WithCancellation(ct))
            {
                var results = await task;
                models.AddRange(results);
            }

            models = models
                .Select(y => new { Package = y, Score = MatchObject(query, y.Name, y.Summary) })
                .Where(x => x.Score >= MatchScore)
                .OrderByDescending(x => x.Score)
                .ThenByDescending(x => x.Package.IsInstalled)
                .ThenBy(x => x.Package.Name, StringComparer.OrdinalIgnoreCase)
                .Select(x => x.Package)
                .ToList();

            GLib.Functions.IdleAdd(0, () =>
            {
                _listStore.RemoveAll();
                foreach (var model in models)
                {
                    var o = MetaPackageGObject.NewWithProperties([]);
                    o.Package = model;
                    _listStore.Append(o);
                }

                return false;
            });
        }
        catch (OperationCanceledException)
        {
            // expected on dispose
        }
        catch (Exception ex)
        {
            Console.WriteLine(T("Search error: {0}", ex.Message));
        }
        finally
        {
            SetLoadingState(false);
        }
    }

    private void SetLoadingState(bool loading)
    {
        GLib.Functions.IdleAdd(0, () =>
        {
            if (loading)
            {
                _searchSpinner.Start();
                _searchStack.SetVisibleChildName("loading");
            }
            else
            {
                _searchSpinner.Stop();
                _searchStack.SetVisibleChildName("results");
            }

            return false;
        });
    }

    private async Task<List<MetaPackageModel>> LoadStandardPackagesAsync(string query)
    {
        var installed = await unprivilegedOperationService.GetInstalledPackagesAsync();
        var installedNames = installed.Select(p => p.Name).ToHashSet();

        var available = await unprivilegedOperationService.SearchPackagesAsync(query);
        return available
            .Select(y => new MetaPackageModel(
                y.Name,
                y.Name,
                y.Version,
                y.Description,
                PackageType.Standard,
                y.Description,
                y.Repository,
                installedNames.Contains(y.Name),
                new DateTimeOffset(y.BuildDate).ToUnixTimeSeconds()
            ))
            .ToList();
    }

    private async Task<List<MetaPackageModel>> LoadAurPackagesAsync(string query)
    {
        var installed = await unprivilegedOperationService.GetAurInstalledPackagesAsync();
        var installedNames = installed.Select(p => p.Name).ToHashSet();

        var available = await unprivilegedOperationService.SearchAurPackagesAsync(query);
        return available
            .Select(y => new MetaPackageModel(
                y.Name,
                y.Name,
                y.Version,
                y.Description ?? "",
                PackageType.Aur,
                y.Description ?? "",
                "AUR",
                installedNames.Contains(y.Name),
                y.LastModified
            ))
            .ToList();
    }

    private async Task<List<MetaPackageModel>> LoadFlatpakPackagesAsync(string query, CancellationToken ct)
    {
        var syncTask = unprivilegedOperationService.FlatpakSyncRemoteAppstream();
        await Task.WhenAny(syncTask, Task.Delay(TimeSpan.FromSeconds(5), ct));

        var installedIds = (await unprivilegedOperationService.ListFlatpakPackages())
            .Select(y => y.Id).ToHashSet();

        var allApps = await unprivilegedOperationService.ListAppstreamFlatpak();
        return allApps
            .Where(app => app.Type != "addon")
            .Select(app => new { Package = app, Score = MatchObject(query, app.Name, app.Summary) })
            .Where(x => x.Score >= MatchScore)
            .OrderByDescending(x => x.Score)
            .Select(x => x.Package)
            .Take(100)
            .Select(app => new MetaPackageModel(
                app.Id,
                app.Name,
                app.Releases.FirstOrDefault()?.Version ??
                string.Empty,
                app.Description,
                PackageType.Flatpak,
                app.Summary,
                app.Remotes.FirstOrDefault()?.Name ??
                "Flatpak",
                installedIds.Contains(app.Id),
                app.Releases.FirstOrDefault()?.Timestamp ??
                DateTimeOffset.MinValue.ToUnixTimeSeconds()
            ))
            .ToList();
    }

    private static int MatchObject(string query, string name, string description)
    {
        var tier = PackageSearch.Score(name, description, query);
        if (tier == 0) return 0;
        var fuzz = (int)(StringMatching.PartialRatio(query, name) * 0.7
                       + StringMatching.PartialRatio(query, description) * 0.3);
        return tier * 1000 + fuzz;
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
            lockoutService.Show(T($"Installing..."));
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
            Console.WriteLine(T("Failed to install packages: {0}", e.Message));
        }
        finally
        {
            lockoutService.Hide();
            ToastMessageEventArgs args;
            if (installFailed)
            {
                args = new ToastMessageEventArgs(
                    T("Install for {0} package(s) was unsuccessful.", selected.Count)
                );
            }
            else
            {
                args = new ToastMessageEventArgs(
                    T("Installed {0} Package(s)", selected.Count)
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
            lockoutService.Show(T("Removing..."));

            var standard = selected.Where(x => x.PackageType == PackageType.Standard).Select(x => x.Name).ToList();
            var aur = selected.Where(x => x.PackageType == PackageType.Aur).Select(x => x.Name).ToList();
            var flatpak = selected.Where(x => x.PackageType == PackageType.Flatpak).Select(x => x.Id).ToList();

            if (standard.Count > 0) await privilegedOperationService.RemovePackagesAsync(standard, true, false, true, _deletePackageCache);
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
            Console.WriteLine(T("Failed to remove packages: {0}", e.Message));
        }
        finally
        {
            lockoutService.Hide();

            var args = new ToastMessageEventArgs(
                T("Removed {0} Package(s)", selected.Count)
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
        _checkBinding.Clear();
        _installedBinding.Clear();
    }
}