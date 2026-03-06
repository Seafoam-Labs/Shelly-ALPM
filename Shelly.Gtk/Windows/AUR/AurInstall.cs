using System.Globalization;
using Gtk;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AUR.GObjects;
using Shelly.Gtk.Windows.Dialog;

namespace Shelly.Gtk.Windows.AUR;

public class AurInstall(
    IPrivilegedOperationService privilegedOperationService,
    ILockoutService lockoutService) : IShellyWindow
{
    private Box _box = null!;
    private ColumnView _columnView = null!;
    private SingleSelection _selectionModel = null!;
    private Gio.ListStore _listStore = null!;
    private string _searchText = string.Empty;
    private SearchEntry _searchEntry = null!;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromFile("UiFiles/AUR/AurWindow.ui");
        _box = (Box)builder.GetObject("AurInstallWindow")!;
        _columnView = (ColumnView)builder.GetObject("package_grid")!;
        _searchEntry = (SearchEntry)builder.GetObject("search_entry")!;

        var checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        var nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        var votesColumn = (ColumnViewColumn)builder.GetObject("votes_column")!;
        var popColumn = (ColumnViewColumn)builder.GetObject("popularity_column")!;
        var versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        var installButton = (Button)builder.GetObject("install_button")!;

        _listStore = Gio.ListStore.New(AurPackageGObject.GetGType());
        _selectionModel = SingleSelection.New(_listStore);
        _selectionModel.CanUnselect = true;
        _columnView.SetModel(_selectionModel);

        SetupColumns(checkColumn, nameColumn, votesColumn, popColumn, versionColumn);

        _columnView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            if (item is AurPackageGObject pkgObj)
            {
                pkgObj.ToggleSelection();
            }
        };
        installButton.OnClicked += (_, _) => { _ = InstallSelectedAsync(); };
        _searchEntry.OnActivate += (_, _) => { _ = SearchAsync(); };

        return _box;
    }

    private static void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn,
        ColumnViewColumn votesColumn, ColumnViewColumn popColumn, ColumnViewColumn versionColumn)
    {
        var checkFactory = SignalListItemFactory.New();
        checkFactory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var check = new CheckButton { MarginStart = 10, MarginEnd = 10 };
            listItem.SetChild(check);
            
            check.OnToggled += (s, _) =>
            {
                if (listItem.GetItem() is AurPackageGObject pkgObj)
                {
                    pkgObj.IsSelected = s.GetActive();
                }
            };
        };

        checkFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not AurPackageGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;

            checkButton.SetActive(pkgObj.IsSelected);

            pkgObj.OnSelectionToggled += OnExternalToggle;
            return;

            void OnExternalToggle(object? s, EventArgs e)
            {
                if (listItem.GetItem() == pkgObj)
                {
                    checkButton.SetActive(pkgObj.IsSelected);
                }
            }
        };

        checkColumn.SetFactory(checkFactory);
        
        var nameFactory = SignalListItemFactory.New();
        nameFactory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        nameFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not AurPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Name);
            label.Halign = Align.Start;
        };
        nameColumn.SetFactory(nameFactory);
        
        var sizeFactory = SignalListItemFactory.New();
        sizeFactory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        sizeFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not AurPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.NumVotes.ToString(CultureInfo.InvariantCulture));
            label.Halign = Align.End;
        };
        popColumn.SetFactory(sizeFactory);
        
        var versionFactory = SignalListItemFactory.New();
        versionFactory.OnSetup += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        versionFactory.OnBind += (_, args) =>
        {
            var listItem = (ListItem)args.Object;
            if (listItem.GetItem() is not AurPackageGObject { Package: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(pkg.Version);
            label.Halign = Align.End;
        };
        versionColumn.SetFactory(versionFactory);
    }

    private async Task SearchAsync()
    {
        _searchText = _searchEntry.GetText();

        if (!string.IsNullOrWhiteSpace(_searchText))
        {
            var result = await privilegedOperationService.SearchAurPackagesAsync(_searchText);

            Console.WriteLine($"[DEBUG_LOG] Search result: {result.Count}");

            result = result.OrderByDescending(x => x.NumVotes).ToList();
            GLib.Functions.IdleAdd(0, () =>
            {
                _listStore.RemoveAll();
                foreach (var gobject in result.Select(dto => new AurPackageGObject
                         {
                             Package = dto,
                             IsSelected = false
                         }))
                {
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
            try
            {
                lockoutService.Show($"Installing...");
                
              

                var packageBuilds = await privilegedOperationService.GetAurPackageBuild(selectedPackages);

                if (packageBuilds.Count == 0)
                {
                    Console.WriteLine("No packages found.");
                    return;
                }

                foreach (var pkgbuild in packageBuilds)
                {
                    /*var dialog = new PackageBuildDialog();
                    var dialogResult = pkgbuild.PkgBuild != null && await dialog.ShowDialog($"Displaying Package Build {pkgbuild.Name}",
                        pkgbuild.PkgBuild);
                    if (!dialogResult) return;*/
                }
                
                var result = await privilegedOperationService.InstallAurPackagesAsync(selectedPackages);
                if (!result.Success)
                {
                    Console.WriteLine($"Failed to install packages: {result.Error}");
                }
            }
            finally
            {
                lockoutService.Hide();
            }
        }
    }
}