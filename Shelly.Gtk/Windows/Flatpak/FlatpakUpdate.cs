using Gtk;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.GTK.Resources;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Utilities;

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.Flatpak;

public class FlatpakUpdate(
    IUnprivilegedOperationService unprivilegedOperationService,
    ILockoutService lockoutService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService,
    IDirtyService dirtyService) : IShellyWindow, IReloadable
{
    private DirtySubscription? _sub;
    public string[] ListensTo => [DirtyScopes.FlatpakUpdates, DirtyScopes.FlatpakInstalled];
    private ListView? _listView;
    private readonly CancellationTokenSource _cts = new();
    private Gio.ListStore? _listStore;
    private SingleSelection? _selectionModel;
    private List<FlatpakPackageDto> _allPackages = [];
    private string _searchText = string.Empty;
    private SignalListItemFactory? _factory;
    private Label? _noUpdatesLabel;
    private readonly List<StringObject> _stringObjectRefs = [];

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Flatpak/FlatpakUpdateWindow.ui"), -1);
        var box = (Box)builder.GetObject("FlatpakUpdateWindow")!;

        _listView = (ListView)builder.GetObject("installed_flatpaks")!;
        var removeButton = (Button)builder.GetObject("update_button")!;

        _listStore = Gio.ListStore.New(StringObject.GetGType());
        _selectionModel = SingleSelection.New(_listStore);
        _listView.SetModel(_selectionModel);

        _factory = SignalListItemFactory.New();
        _factory.OnSetup += OnSetup;
        _factory.OnBind += OnBind;
        _listView.SetFactory(_factory);
        _noUpdatesLabel = (Label)builder.GetObject("no_updates_label")!;

        _listView.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };
        removeButton.OnClicked += (_, _) => { _ = UpdateAllCommand(); };

        _sub = DirtySubscription.Attach(dirtyService, this);
        return box;
    }

    public void Reload() => _ = LoadDataAsync(_cts.Token);

    private static void OnSetup(SignalListItemFactory sender, SignalListItemFactory.SetupSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        var mainVbox = Box.New(Orientation.Vertical, 0);

        var contentGrid = Grid.New();
        contentGrid.MarginStart = 10;
        contentGrid.MarginEnd = 10;
        contentGrid.MarginTop = 5;
        contentGrid.MarginBottom = 5;
        contentGrid.ColumnSpacing = 10;
        contentGrid.RowSpacing = 2;
        contentGrid.Hexpand = true;

        var icon = Image.New();
        contentGrid.Attach(icon, 0, 0, 1, 2);

        var nameLabel = Label.New(string.Empty);
        nameLabel.Halign = Align.Start;
        contentGrid.Attach(nameLabel, 1, 0, 1, 1);

        var idLabel = Label.New(string.Empty);
        idLabel.Halign = Align.Start;
        idLabel.AddCssClass("dim-label");
        contentGrid.Attach(idLabel, 1, 1, 1, 1);

        var versionLabel = Label.New(string.Empty);
        versionLabel.Halign = Align.End;
        versionLabel.Hexpand = true;
        contentGrid.Attach(versionLabel, 2, 0, 1, 2);

        mainVbox.Append(contentGrid);

        var permissionExpander = Expander.New(Translations.T("Permission Changes"));
        permissionExpander.MarginStart = 50;
        permissionExpander.MarginEnd = 10;
        permissionExpander.MarginBottom = 5;
        permissionExpander.Visible = false;

        var permissionVbox = Box.New(Orientation.Vertical, 2);
        permissionExpander.SetChild(permissionVbox);

        mainVbox.Append(permissionExpander);

        listItem.SetChild(mainVbox);
    }

    private void OnBind(SignalListItemFactory sender, SignalListItemFactory.BindSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        if (listItem.GetItem() is not StringObject stringObj) return;
        if (listItem.GetChild() is not Box mainVbox) return;

        var packageId = stringObj.GetString();
        var package = _allPackages.FirstOrDefault(p => p.Id == packageId);
        if (package == null) return;

        var contentGrid = (Grid)mainVbox.GetFirstChild()!;
        var icon = (Image)contentGrid.GetChildAt(0, 0)!;
        var nameLabel = (Label)contentGrid.GetChildAt(1, 0)!;
        var idLabel = (Label)contentGrid.GetChildAt(1, 1)!;
        var versionLabel = (Label)contentGrid.GetChildAt(2, 0)!;

        var permissionExpander = (Expander)mainVbox.GetLastChild()!;
        var permissionVbox = (Box)permissionExpander.GetChild()!;

        string path;
        if (package.InstallLevel == InstallLevel.User)
        {
            path =
                Path.Combine(XdgPaths.DataHome(), "flatpak/appstream", package.Remote,
                    "x86_64/active/icons/64x64", $"{package.Id}.png");
        }
        else
        {
            path =
                $"/var/lib/flatpak/appstream/{package.Remote}/x86_64/active/icons/64x64/{package.Id}.png";
        }

        if (File.Exists(path))
            icon.SetFromFile(path);
        else
            icon.SetFromIconName("application-x-executable");

        nameLabel.SetText(package.Name);
        idLabel.SetText(package.Id);
        versionLabel.SetText(package.Version);

        var child = permissionVbox.GetFirstChild();
        while (child != null)
        {
            var next = child.GetNextSibling();
            permissionVbox.Remove(child);
            child = next;
        }

        if (package.Permissions.Count > 0)
        {
            permissionExpander.Visible = true;
            foreach (var perm in package.Permissions)
            {
                var permLabel = Label.New(perm);
                permLabel.Halign = Align.Start;
                if ("+".StartsWith(perm))
                {
                    permLabel.AddCssClass("success");
                }
                else if ("-".StartsWith(perm))
                {
                    permLabel.AddCssClass("error");
                }

                permissionVbox.Append(permLabel);
            }
        }
        else
        {
            permissionExpander.Visible = false;
        }
    }

    private async Task LoadDataAsync(CancellationToken ct = default)
    {
        try
        {
            _allPackages = await unprivilegedOperationService.ListFlatpakUpdates();
            ct.ThrowIfCancellationRequested();

            GLib.Functions.IdleAdd(0, () =>
            {
                ApplyFilter();
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load installed packages: {e.Message}");
        }
    }

    public void SetSearch(string text)
    {
        _searchText = text;
        ApplyFilter();
    }

    private void ApplyFilter()
    {
        if (_listStore == null) return;

        var filtered = string.IsNullOrWhiteSpace(_searchText)
            ? _allPackages
            : _allPackages.Where(p =>
                p.Name.Contains(_searchText, StringComparison.OrdinalIgnoreCase) ||
                p.Id.Contains(_searchText, StringComparison.OrdinalIgnoreCase));

        _listStore.RemoveAll();
        _stringObjectRefs.Clear();

        foreach (var package in filtered)
        {
            var strObj = StringObject.New(package.Id);
            _stringObjectRefs.Add(strObj);
            _listStore.Append(strObj);
        }

        if (_listStore.GetNItems() != 0) return;
        _noUpdatesLabel!.Label_ = (Translations.T("<span size='large'>Flatpaks are up to date</span>"));
        _noUpdatesLabel.Visible = true;
    }

    private async Task UpdateAllCommand()
    {
        if (!configService.LoadConfig().NoConfirmSettings.Resolve(configService.LoadConfig().NoConfirmSettings.FlatpakUpgrade))
        {
            var args = new GenericQuestionEventArgs(
                Translations.T("Update Packages?"), string.Join("\n", _allPackages.Select(x => x.Id))
            );

            genericQuestionService.RaiseQuestion(args);
            if (!await args.ResponseTask)
            {
                return;
            }
        }

        try
        {
            lockoutService.Show(Translations.T("Updating Flatpak packages..."));
            var result = await unprivilegedOperationService.FlatpakUpgrade();

            if (!result.Success)
            {
                Console.WriteLine(Translations.T("Failed to update packages: {0}", result.Error));
            }

            await LoadDataAsync();
        }
        finally
        {
            lockoutService.Hide();

            var args = new ToastMessageEventArgs(
                Translations.T("Updated all Flatpak(s)")
            );

            genericQuestionService.RaiseToastMessage(args);
        }
    }

    public void Dispose()
    {
        _sub?.Dispose();
        _cts.Cancel();
        _cts.Dispose();
        _listStore?.RemoveAll();
        _stringObjectRefs.Clear();
        _allPackages.Clear();
    }
}