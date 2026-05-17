using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;
using Functions = GLib.Functions;
using ListStore = Gio.ListStore;

namespace Shelly.Gtk.Windows.Packages;

public sealed class RemoveLocal(
    IPrivilegedOperationService privilegedOperationService,
    ILockoutService lockoutService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService,
    IDirtyService dirtyService) : IShellyWindow, IReloadable
{
    private DirtySubscription? _sub;
    public string[] ListensTo => [DirtyScopes.Native, DirtyScopes.NativeInstalled];
    private CancellationTokenSource _cts = new();
    private int _loadGeneration;
    private readonly ListStore _listStore = ListStore.New(LocalPackageGObject.GetGType());

    private Button _removeButton = null!;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Package/RemoveLocalWindow.ui"), -1);
        var box = (Box)builder.GetObject("RemoveLocalWindow")!;
        var columnView = (ColumnView)builder.GetObject("package_grid")!;

        var checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        checkColumn.Resizable = true;
        var nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        nameColumn.Resizable = true;
        var sizeColumn = (ColumnViewColumn)builder.GetObject("size_column")!;
        sizeColumn.Resizable = true;

        _removeButton = (Button)builder.GetObject("remove_button")!;
        _removeButton.SetSensitive(false);

        _listStore.RemoveAll();
        var selectionModel = SingleSelection.New(_listStore);
        selectionModel.CanUnselect = true;
        selectionModel.Autoselect = false;
        columnView.SetModel(selectionModel);

        SetupColumns(checkColumn, nameColumn, sizeColumn);

        ColumnViewHelper.AlignColumnHeader(columnView, 1, Align.Start);
        ColumnViewHelper.AlignColumnHeader(columnView, 2, Align.End);
        ColumnViewHelper.AlignColumnHeader(columnView, 3, Align.End);

        columnView.OnRealize += (_, _) => { Reload(); };
        columnView.OnActivate += (_, _) =>
        {
            var item = selectionModel.GetSelectedItem();
            if (item is LocalPackageGObject pkgObj)
            {
                pkgObj.ToggleSelection();
            }
        };
        _removeButton.OnClicked += (_, _) => { _ = RemoveSelectedAsync(); };
        _sub = DirtySubscription.Attach(dirtyService, this);
        return box;
    }

    public void Reload()
    {
        var old = Interlocked.Exchange(ref _cts, new CancellationTokenSource());
        old.Cancel();
        old.Dispose();
        Interlocked.Increment(ref _loadGeneration);
        _ = LoadDataAsync(_loadGeneration, _cts.Token);
    }

    private void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn, ColumnViewColumn sizeColumn)
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
                if (listItem.GetItem() is not LocalPackageGObject current) return;
                current.IsSelected = s.GetActive();
                _removeButton.SetSensitive(AnySelected());
            };
        };

        checkFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not LocalPackageGObject pkgObj ||
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

        checkFactory.OnUnbind += (_, _) => { };

        checkFactory.OnTeardown += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not LocalPackageGObject ||
                listItem.GetChild() is not CheckButton) return;
            listItem.SetChild(null);
        };
        checkColumn.SetFactory(checkFactory);

        var nameFactory = SignalListItemFactory.New();
        nameFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var box = Box.New(Orientation.Horizontal, 6);

            var packageIcon = Image.New();
            packageIcon.PixelSize = 24;
            var label = Label.New(string.Empty);

            box.Append(packageIcon);
            box.Append(label);

            listItem.SetChild(box);
        };
        nameFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not LocalPackageGObject pkgObj ||
                listItem.GetChild() is not Box box ||
                pkgObj.Package is null) return;

            var pkg = pkgObj.Package;

            var packageIcon = (Image)box.GetFirstChild()!;
            var label = (Label)packageIcon.GetNextSibling()!;

            packageIcon.SetFromIconName("package-x-generic");
            packageIcon.Visible = true;

            label.SetText(pkg.Name);
            label.Halign = Align.Start;
        };
        nameColumn.SetFactory(nameFactory);

        var sizeFactory = SignalListItemFactory.New();
        sizeFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        sizeFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not LocalPackageGObject pkgObj ||
                listItem.GetChild() is not Label label ||
                pkgObj.Package is null) return;

            label.SetText(SizeHelpers.FormatSize(pkgObj.Package.Size));
            label.Halign = Align.End;
        };
        sizeColumn.SetFactory(sizeFactory);
    }

    private async Task LoadDataAsync(int generation = 0, CancellationToken ct = default)
    {
        try
        {
            var packages = await privilegedOperationService.GetLocalInstalledPackagesAsync();
            ct.ThrowIfCancellationRequested();
            Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested || _loadGeneration != generation) return false;

                _listStore.RemoveAll();
                _removeButton.SetSensitive(false);

                foreach (var package in packages)
                {
                    var pkgObj = LocalPackageGObject.NewWithProperties([]);
                    pkgObj.Package = package;
                    _listStore.Append(pkgObj);
                }

                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load packages: {e.Message}");
        }
    }

    private async Task RemoveSelectedAsync()
    {
        var selectedPackages = new List<string>();
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is LocalPackageGObject { IsSelected: true, Package: not null } pkgObj)
            {
                selectedPackages.Add(pkgObj.Package.Name);
            }
        }

        if (selectedPackages.Count != 0)
        {
            if (!configService.LoadConfig().NoConfirm)
            {
                var args = new GenericQuestionEventArgs(
                    "Remove Packages?", string.Join("\n", selectedPackages)
                );

                genericQuestionService.RaiseQuestion(args);
                if (!await args.ResponseTask)
                {
                    return;
                }
            }

            try
            {
                lockoutService.Show("Removing...");
                var result = await privilegedOperationService.RemoveLocalPackagesAsync(selectedPackages);
                if (result.Success)
                {
                    var args = new ToastMessageEventArgs(
                        $"Removed {selectedPackages.Count} Package(s)"
                    );
                    genericQuestionService.RaiseToastMessage(args);
                }

                Reload();
            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to remove packages: {e.Message}");
            }
            finally
            {
                lockoutService.Hide();
            }
        }
    }

    private bool AnySelected()
    {
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is LocalPackageGObject { IsSelected: true })
                return true;
        }

        return false;
    }

    public void Dispose()
    {
        _sub?.Dispose();
        _cts.Cancel();
        _cts.Dispose();

        _listStore.RemoveAll();
        _listStore.Dispose();
    }
}
