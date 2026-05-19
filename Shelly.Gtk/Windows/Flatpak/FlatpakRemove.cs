using Gtk;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.GTK.Resources;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.Flatpak;

public class FlatpakRemove(
    IUnprivilegedOperationService unprivilegedOperationService,
    ILockoutService lockoutService,
    IGenericQuestionService genericQuestionService,
    IDirtyService dirtyService) : IShellyWindow, IReloadable
{
    private DirtySubscription? _sub;
    public string[] ListensTo => [DirtyScopes.FlatpakInstalled];
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
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Flatpak/FlatpakRemoveWindow.ui"), -1);
        var box = (Box)builder.GetObject("FlatpakRemoveWindow")!;

        _listView = (ListView)builder.GetObject("installed_flatpaks")!;
        var removeButton = (Button)builder.GetObject("remove_button")!;

        _listStore = Gio.ListStore.New(StringObject.GetGType());
        _selectionModel = SingleSelection.New(_listStore);
        _listView.SetModel(_selectionModel);

        _factory = SignalListItemFactory.New();
        _factory.OnSetup += OnSetup;
        _factory.OnBind += OnBind;
        _listView.SetFactory(_factory);

        _listView.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };
        removeButton.OnClicked += (_, _) => { _ = RemoveSelectedAsync(); };

        _sub = DirtySubscription.Attach(dirtyService, this);
        return box;
    }

    public void Reload() => _ = LoadDataAsync(_cts.Token);

    private static void OnSetup(SignalListItemFactory sender, SignalListItemFactory.SetupSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
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

        listItem.SetChild(hbox);
    }

    private void OnBind(SignalListItemFactory sender, SignalListItemFactory.BindSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        if (listItem.GetItem() is not StringObject stringObj) return;
        if (listItem.GetChild() is not Box hbox) return;

        var packageId = stringObj.GetString();
        var package = _allPackages.FirstOrDefault(p => p.Id == packageId);
        if (package == null) return;

        var icon = (Image)hbox.GetFirstChild()!;
        var vbox = (Box)icon.GetNextSibling()!;
        var nameLabel = (Label)vbox.GetFirstChild()!;
        var idLabel = (Label)nameLabel.GetNextSibling()!;
        var versionLabel = (Label)vbox.GetNextSibling()!;

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
    }

    private async Task LoadDataAsync(CancellationToken ct = default)
    {
        try
        {
            _allPackages = await unprivilegedOperationService.ListFlatpakPackages();
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

    private static GenericDialogEventArgs<FlatpakRemoveEnum> BuildRemoveDialog()
    {
        var keepRadio = CheckButton.New();
        var deleteRadio = CheckButton.New();
        deleteRadio.SetGroup(keepRadio);
        keepRadio.Active = true;

        var listBox = ListBox.New();
        listBox.SelectionMode = SelectionMode.None;
        listBox.AddCssClass("boxed-list");

        var firstRadio = MakeRow(keepRadio, Translations.T("Keep Config"), Translations.T("Keep user data and configuration"));
        var secondRadio = MakeRow(deleteRadio, Translations.T("Delete Config"), Translations.T("Delete user data and configuration"));
        listBox.Append(firstRadio);
        listBox.Append(secondRadio);

        var gestureKeep = GestureClick.New();
        gestureKeep.OnReleased += (_, _) => keepRadio.Active = true;
        firstRadio.AddController(gestureKeep);

        var gestureRemove = GestureClick.New();
        gestureRemove.OnReleased += (_, _) => deleteRadio.Active = true;
        secondRadio.AddController(gestureRemove);

        var keepLabel = Label.New(Translations.T("Keep Config?"));
        keepLabel.AddCssClass("heading");

        var box = Box.New(Orientation.Vertical, 12);
        box.Append(keepLabel);
        box.Append(listBox);

        var buttonBox = Box.New(Orientation.Horizontal, 0);

        var dialogArgs = new GenericDialogEventArgs<FlatpakRemoveEnum>(box);

        var closeButton = Button.NewWithLabel(Translations.T("Close"));
        closeButton.OnClicked += (_, _) => dialogArgs.SetResponse(FlatpakRemoveEnum.Cancel);

        var removeButton = Button.NewWithLabel(Translations.T("Confirm"));
        removeButton.AddCssClass("suggested-action");
        removeButton.OnClicked += (_, _) =>
        {
            dialogArgs.SetResponse(keepRadio.Active
                ? FlatpakRemoveEnum.KeepConfig
                : FlatpakRemoveEnum.RemoveConfig);
        };

        closeButton.Hexpand = false;
        removeButton.Hexpand = false;

        buttonBox.Halign = Align.Fill;
        buttonBox.Hexpand = true;
        buttonBox.Homogeneous = true;
        buttonBox.Spacing = 5;
        buttonBox.Append(removeButton);
        buttonBox.Append(closeButton);
        box.Append(buttonBox);

        return dialogArgs;

        ListBoxRow MakeRow(CheckButton radio, string title, string subtitle)
        {
            var titleLabel = Label.New(title);
            titleLabel.Halign = Align.Start;

            var subtitleLabel = Label.New(subtitle);
            subtitleLabel.Halign = Align.Start;
            subtitleLabel.AddCssClass("dim-label");
            subtitleLabel.SetEllipsize(Pango.EllipsizeMode.End);

            var textBox = Box.New(Orientation.Vertical, 2);
            textBox.Hexpand = true;
            textBox.Append(titleLabel);
            textBox.Append(subtitleLabel);

            var rowBox = Box.New(Orientation.Horizontal, 12);
            rowBox.MarginTop = 10;
            rowBox.MarginBottom = 10;
            rowBox.MarginStart = 12;
            rowBox.MarginEnd = 12;
            radio.Valign = Align.Center;
            rowBox.Append(radio);
            rowBox.Append(textBox);

            var row = ListBoxRow.New();
            row.Child = rowBox;
            row.Activatable = true;
            row.OnActivate += (_, _) => radio.Active = true;
            return row;
        }
    }

    private async Task RemoveSelectedAsync()
    {
        var selectedItem = _selectionModel?.GetSelectedItem();
        if (selectedItem is not StringObject stringObj) return;

        var packageId = stringObj.GetString();
        bool removeConfig;

        var args = BuildRemoveDialog();

        genericQuestionService.RaiseDialog(args);

        var message = await args.ResponseTask;

        switch (message)
        {
            case FlatpakRemoveEnum.Cancel:
                return;
            case FlatpakRemoveEnum.KeepConfig:
                removeConfig = false;
                break;
            case FlatpakRemoveEnum.RemoveConfig:
                removeConfig = true;
                break;
            default:
                throw new ArgumentOutOfRangeException();
        }

        try
        {
            lockoutService.Show(Translations.T("Removing {0}...", packageId));
            var result = await unprivilegedOperationService.RemoveFlatpakPackage(packageId, removeConfig);

            if (!result.Success)
            {
                Console.WriteLine(Translations.T("Failed to remove package {0}: {1}", packageId, result.Error));
            }
            else
            {
                await LoadDataAsync();
            }
        }
        finally
        {
            lockoutService.Hide();
            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(
                Translations.T("Removed Package(s)")
            ));
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