using System.Globalization;
using System.Text;
using GObject;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AUR.GObjects;
using Shelly.Gtk.Windows.Dialog;

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.AUR;

public class AurInstall(
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
    private string _searchText = string.Empty;
    private SearchEntry _searchEntry = null!;
    private SignalListItemFactory _checkFactory = null!;
    private SignalListItemFactory _nameFactory = null!;
    private SignalListItemFactory _votesFactory = null!;
    private SignalListItemFactory _popFactory = null!;
    private SignalListItemFactory _versionFactory = null!;

    private Dictionary<ColumnViewCell, (SignalHandler<CheckButton> OnToggled, EventHandler OnExternalToggle)>
        _checkBinding = [];

    private readonly List<AurPackageGObject> _packageGObjectRefs = [];
    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _votesColumn = null!;
    private ColumnViewColumn _popColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private Button _installButton = null!;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/AUR/AurWindow.ui"), -1);
        _box = (Box)builder.GetObject("AurInstallWindow")!;
        _columnView = (ColumnView)builder.GetObject("package_grid")!;
        _searchEntry = (SearchEntry)builder.GetObject("search_entry")!;

        _checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        _checkColumn.Resizable = true;

        _nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        _nameColumn.Resizable = true;

        _votesColumn = (ColumnViewColumn)builder.GetObject("votes_column")!;
        _votesColumn.Resizable = true;

        _popColumn = (ColumnViewColumn)builder.GetObject("popularity_column")!;
        _popColumn.Resizable = true;

        _versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        _versionColumn.Resizable = true;
        _installButton = (Button)builder.GetObject("install_button")!;
        _installButton.SetSensitive(false);
        _listStore = Gio.ListStore.New(AurPackageGObject.GetGType());
        _selectionModel = SingleSelection.New(_listStore);
        _selectionModel.CanUnselect = true;
        _columnView.SetModel(_selectionModel);

        SetupColumns(_checkColumn, _nameColumn, _votesColumn, _popColumn, _versionColumn);

        ColumnViewHelper.AlignColumnHeader(_columnView, 1, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 2, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 3, Align.End);

        _columnView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            if (item is AurPackageGObject pkgObj)
            {
                pkgObj.ToggleSelection();
                _installButton.SetSensitive(AnySelected());
            }
        };
        _installButton.OnClicked += (_, _) => { _ = InstallSelectedAsync(); };
        _searchEntry.OnActivate += (_, _) => { _ = SearchAsync(_cts.Token); };

        return _box;
    }

    private void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn,
        ColumnViewColumn votesColumn, ColumnViewColumn popColumn, ColumnViewColumn versionColumn)
    {
        var checkFactory = _checkFactory = SignalListItemFactory.New();
        checkFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var check = new CheckButton { MarginStart = 10, MarginEnd = 10 };
            listItem.SetChild(check);
        };

        checkFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject pkgObj ||
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

        checkFactory.OnUnbind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;
            if (_checkBinding.Remove(listItem, out var handlers))
            {
                pkgObj.OnSelectionToggled -= handlers.OnExternalToggle;
                checkButton.OnToggled -= handlers.OnToggled;
            }
        };

        checkColumn.SetFactory(checkFactory);

        var nameFactory = _nameFactory = SignalListItemFactory.New();
        nameFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        nameFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Name);
            label.Halign = Align.Start;
        };
        nameColumn.SetFactory(nameFactory);

        var votesFactory = _votesFactory = SignalListItemFactory.New();
        votesFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        votesFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.NumVotes.ToString(CultureInfo.InvariantCulture));
            label.Halign = Align.End;
        };
        votesColumn.SetFactory(votesFactory);

        var sizeFactory = _popFactory = SignalListItemFactory.New();
        sizeFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        sizeFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Popularity.ToString("F2", CultureInfo.InvariantCulture));
            label.Halign = Align.End;
        };
        popColumn.SetFactory(sizeFactory);

        var versionFactory = _versionFactory = SignalListItemFactory.New();
        versionFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        versionFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Version);
            label.Halign = Align.End;
        };
        versionColumn.SetFactory(versionFactory);
    }

    private async Task SearchAsync(CancellationToken ct)
    {
        _searchText = _searchEntry.GetText();

        if (!string.IsNullOrWhiteSpace(_searchText))
        {
            var result = await privilegedOperationService.SearchAurPackagesAsync(_searchText);
            ct.ThrowIfCancellationRequested();

            Console.WriteLine($"[DEBUG_LOG] Search result: {result.Count}");

            result = result.OrderByDescending(x => x.NumVotes).ToList();
            GLib.Functions.IdleAdd(0, () =>
            {
                _listStore.RemoveAll();
                _packageGObjectRefs.Clear();
                foreach (var gobject in result.Select(dto => new AurPackageGObject
                         {
                             Package = dto,
                             IsSelected = false
                         }))
                {
                    _packageGObjectRefs.Add(gobject);
                    _listStore.Append(gobject);
                }

                return false;
            });
        }
    }

    private async Task InstallSelectedAsync()
    {
        var selectedPackages = new List<string>();
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AurPackageGObject { IsSelected: true, Package: not null } pkgObj)
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

                var packageBuilds = await privilegedOperationService.GetAurPackageBuild(selectedPackages);

                if (packageBuilds.Count == 0)
                {
                    Console.WriteLine("No packages found.");
                    return;
                }

                foreach (var pkgbuild in packageBuilds)
                {
                    if (pkgbuild.PkgBuild == null) continue;

                    var buildArgs =
                        new PackageBuildEventArgs($"Displaying Package Build {pkgbuild.Name}", pkgbuild.PkgBuild);
                    genericQuestionService.RaisePackageBuild(buildArgs);

                    if (!await buildArgs.ResponseTask)
                    {
                        return;
                    }
                }

                result = await privilegedOperationService.InstallAurPackagesAsync(selectedPackages);
                if (!result.Success)
                {
                    Console.WriteLine($"Failed to install packages: {result.Error}");
                }
            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to install packages: {e.Message}");
                result = new OperationResult
                {
                    Success = false,
                    Error = e.ToString(),
                    ExitCode = -1
                };
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
        var dialogArgs = AurInstallFailureDialog.Create(
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
            dialog.SetTitle("Export AUR install log");
            dialog.SetInitialName(LogHelpers.CreateSuggestedLogFileName(selectedPackages, "aur"));

            var filter = FileFilter.New();
            filter.SetName("Log Files (*.log)");
            filter.AddPattern("*.log");

            var filters = Gio.ListStore.New(FileFilter.GetGType());
            filters.Append(filter);
            dialog.SetFilters(filters);

            var file = await dialog.SaveAsync((Window)_box.GetRoot()!);
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

            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs("Exported AUR install log"));
            return true;
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to export AUR install log: {e.Message}");
            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs("Failed to export AUR install log"));
            return false;
        }
    }


    private bool AnySelected()
    {
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AurPackageGObject { IsSelected: true })
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
    }
}