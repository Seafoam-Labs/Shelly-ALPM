using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.GTK.Resources;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;

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
    private readonly List<StringObject> _stringObjectRefs = [];
    private bool _userOnly;

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
        
        var hbox = Box.New(Orientation.Horizontal, 10);
        hbox.MarginStart = 10;
        hbox.MarginEnd = 10;
        hbox.MarginTop = 5;
        hbox.MarginBottom = 5;

        var icon = Image.New();
        hbox.Append(icon);

        var vbox = Box.New(Orientation.Vertical, 2);
        var nameLabel = Label.New(string.Empty);
        nameLabel.Halign = Align.Start;

        var idLabel = Label.New(string.Empty);
        idLabel.Halign = Align.Start;
        idLabel.AddCssClass("dim-label");

        vbox.Append(nameLabel);
        vbox.Append(idLabel);
        hbox.Append(vbox);

        var versionLabel = Label.New(string.Empty);
        versionLabel.Halign = Align.End;
        versionLabel.Hexpand = true;
        hbox.Append(versionLabel);
        
        mainVbox.Append(hbox);

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

        var hbox = (Box)mainVbox.GetFirstChild()!;
        var icon = (Image)hbox.GetFirstChild()!;
        var vbox = (Box)icon.GetNextSibling()!;
        var nameLabel = (Label)vbox.GetFirstChild()!;
        var idLabel = (Label)nameLabel.GetNextSibling()!;
        var versionLabel = (Label)hbox.GetLastChild()!;

        var permissionExpander = (Expander)hbox.GetNextSibling()!;
        var permissionVbox = (Box)permissionExpander.GetChild()!;

        string path;
        if (_userOnly)
        {
            var userHome = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            path =
                Path.Combine(userHome, ".local/share/flatpak/appstream", package.Remote,
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

            var remotes = await unprivilegedOperationService.FlatpakListRemotes();

            GLib.Functions.IdleAdd(0, () =>
            {
                _userOnly = remotes.Any(r => r.Scope != "system");
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
    }

    private async Task UpdateAllCommand()
    {
        if (!configService.LoadConfig().NoConfirm)
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