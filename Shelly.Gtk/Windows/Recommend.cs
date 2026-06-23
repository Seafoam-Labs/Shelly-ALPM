using System.Net;
using System.Text.Json;
using Gtk;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.Icons;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.Recommend;
using Shelly.Utilities;
using static Shelly.GTK.Resources.Translations;
using Functions = GLib.Functions;
using WrapMode = Pango.WrapMode;

namespace Shelly.Gtk.Windows;

public sealed class Recommend(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    IGenericQuestionService genericQuestionService,
    ILockoutService lockoutService,
    IIconResolverService iconResolverService) : IShellyWindow, IReloadable
{
    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AutomaticDecompression = DecompressionMethods.All,
        AllowAutoRedirect = true,
        MaxAutomaticRedirections = 10,
        ConnectTimeout = TimeSpan.FromSeconds(30),
        EnableMultipleHttp2Connections = true,
        EnableMultipleHttp3Connections = true
    })
    {
        Timeout = TimeSpan.FromMinutes(1),
        DefaultRequestHeaders = { UserAgent = { Http.UserAgent } },
        DefaultRequestVersion = HttpVersion.Version11,
        DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrHigher
    };

    private readonly CancellationTokenSource _cts = new();
    private readonly List<FlatRecommendModel> _packages = [];
    private Box? _loadingOverlay;
    private Spinner? _loadingSpinner;
    private Box? _noResultsOverlay;
    private Box? _scrolledWindow;

    public string[] ListensTo { get; } = [];

    public void Reload()
    {
        // Never needs to reload logic here, since the data is static and the page handles the refreshing its state itself.
    }

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Recommend.ui"), -1);
        builder.TranslationDomain = Domain;
        var overlay = (Overlay)builder.GetObject("ShellyRecommend")!;

        _scrolledWindow = (Box)builder.GetObject("recommend_scroll_window")!;
        _scrolledWindow.SetOrientation(Orientation.Vertical);
        _scrolledWindow.SetSpacing(10);

        _loadingOverlay = (Box)builder.GetObject("loading_overlay")!;
        _loadingSpinner = (Spinner)builder.GetObject("loading_spinner")!;

        _noResultsOverlay = Box.New(Orientation.Vertical, 12);
        _noResultsOverlay.SetValign(Align.Center);
        _noResultsOverlay.SetHalign(Align.Center);
        _noResultsOverlay.AddCssClass("dim-label");
        _noResultsOverlay.SetVisible(false);

        var noResultsIcon = Image.NewFromIconName("search-none-symbolic");
        noResultsIcon.SetPixelSize(64);

        var noResultsLabel =
            Label.New(T("No recommendations found. Please check your internet connection and try again."));
        noResultsLabel.AddCssClass("title-2");

        _noResultsOverlay.Append(noResultsIcon);
        _noResultsOverlay.Append(noResultsLabel);

        overlay.AddOverlay(_noResultsOverlay);

        _scrolledWindow.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };

        return overlay;
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
        _packages.Clear();
        _noResultsOverlay?.Dispose();
        _scrolledWindow?.Dispose();
    }

    private async Task LoadDataAsync(CancellationToken ct)
    {
        try
        {
            Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested) return false;
                _loadingOverlay?.SetVisible(true);
                _loadingSpinner?.Start();
                return false;
            });

            var alpmPackages = await unprivilegedOperationService.GetAvailablePackagesAsync();
            var installedPackages = await unprivilegedOperationService.GetInstalledPackagesAsync();

            var response = await Client.GetAsync("https://www.seafoam-labs.org/recommend.json", ct);
            response.EnsureSuccessStatusCode();
            var values = await response.Content.ReadAsStringAsync(ct);

            var result = JsonSerializer.Deserialize(values, RecommendJsonContext.Default.ListRecommendModel) ?? [];

            // Build package list on background thread (no GTK calls)
            var packages = new List<FlatRecommendModel>();
            foreach (var item in result)
            {
                if (!Enum.TryParse<RecommendCategory>(item.Name, out var category)) continue;
                foreach (var pkgName in item.Packages.Where(pkgName => alpmPackages.Any(x => x.Name == pkgName)))
                    packages.Add(new FlatRecommendModel
                    {
                        Category = category,
                        Package = pkgName,
                        Description = alpmPackages.FirstOrDefault(x => x.Name == pkgName)?.Description ?? "",
                        IsInstalled = installedPackages.Any(x => x.Name == pkgName),
                        Version = alpmPackages.FirstOrDefault(x => x.Name == pkgName)?.Version ?? "",
                        Repository = alpmPackages.FirstOrDefault(x => x.Name == pkgName)?.Repository ?? ""
                    });
            }

            // All GTK widget operations must run on the main thread via IdleAdd
            Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested) return false;

                if (packages.Count < 1)
                {
                    _noResultsOverlay?.SetVisible(true);
                    return false;
                }

                _noResultsOverlay?.SetVisible(false);
                _packages.Clear();
                _packages.AddRange(packages);
                FlowChartBuilder();
                return false;
            });
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
        finally
        {
            Functions.IdleAdd(0, () =>
            {
                // We always try to hide it, but only if not disposed
                _loadingOverlay?.SetVisible(false);
                _loadingSpinner?.Stop();
                return false;
            });
        }
    }

    private Task FlowChartBuilder()
    {
        try
        {
            var sizeGroup = SizeGroup.New(SizeGroupMode.Vertical);

            foreach (var category in Enum.GetValues<RecommendCategory>())
            {
                var categoryPackages = _packages.Where(x => x.Category == category).ToList();
                if (categoryPackages.Count == 0) continue;

                var sectionBox = Box.New(Orientation.Vertical, 6);

                var label = Label.New(T(category.GetDescription()));
                label.SetHalign(Align.Start);
                label.AddCssClass("title-4");

                var flox = FlowBox.New();
                flox.SetSelectionMode(SelectionMode.None);
                flox.SetColumnSpacing(8);
                flox.SetRowSpacing(8);
                flox.Homogeneous = true;
                flox.MinChildrenPerLine = 1;
                flox.MaxChildrenPerLine = 6;

                foreach (var item in categoryPackages) AddFlowBoxItem(flox, item, sizeGroup);

                sectionBox.Append(label);
                sectionBox.Append(flox);

                _scrolledWindow!.Append(sectionBox);
            }

            return Task.CompletedTask;
        }
        catch (Exception exception)
        {
            return Task.FromException(exception);
        }
    }

    private void AddFlowBoxItem(FlowBox flowBox, FlatRecommendModel item, SizeGroup sizeGroup)
    {
        var contentBox = Box.New(Orientation.Horizontal, 10);
        contentBox.SetMarginTop(8);
        contentBox.SetMarginBottom(8);
        contentBox.SetMarginStart(10);
        contentBox.SetMarginEnd(10);
        contentBox.SetHexpand(true);

        var iconPath = iconResolverService.GetIconPath(item.Package);

        var image = Image.NewFromFile(string.IsNullOrWhiteSpace(iconPath) ? "package-x-generic" : iconPath);
        image.SetPixelSize(48);
        image.SetValign(Align.Center);
        image.AddCssClass("icon-dropshadow");
        contentBox.Append(image);

        var textContainer = Box.New(Orientation.Vertical, 0);
        textContainer.SetValign(Align.Center);
        textContainer.SetHexpand(true);

        var titleContainer = Box.New(Orientation.Horizontal, 6);

        var titleLabel = Label.New(item.Package);
        titleLabel.SetHalign(Align.Start);
        titleLabel.AddCssClass("title-4");

        var versionLabel = Label.New(item.Version);
        versionLabel.SetHalign(Align.Start);
        versionLabel.SetValign(Align.Center);
        versionLabel.AddCssClass("caption");

        var installedCheck = Image.NewFromIconName("object-select-symbolic");
        installedCheck.SetVisible(item.IsInstalled);
        installedCheck.SetValign(Align.Center);
        installedCheck.SetTooltipText(T("Package is already installed"));

        titleContainer.Append(titleLabel);
        titleContainer.Append(versionLabel);
        titleContainer.Append(installedCheck);

        var descLabel = Label.New(item.Description);
        descLabel.SetHalign(Align.Start);
        descLabel.SetValign(Align.Start);
        descLabel.AddCssClass("dim-label");
        descLabel.SetWrap(true);
        descLabel.SetWrapMode(WrapMode.WordChar);
        descLabel.SetLines(2);
        descLabel.MaxWidthChars = 40;
        descLabel.NaturalWrapMode = NaturalWrapMode.None;

        textContainer.Append(titleContainer);
        textContainer.Append(descLabel);

        contentBox.Append(textContainer);

        var removeButton = Button.NewFromIconName("edit-delete-symbolic");
        var downloadButton = Button.NewFromIconName("folder-download-symbolic");

        removeButton.SetVisible(item.IsInstalled);
        removeButton.AddCssClass("destructive-action");
        removeButton.SetValign(Align.Center);
        removeButton.SetTooltipText(T("Remove ") + item.Package);
        removeButton.OnClicked += async (_, _) =>
        {
            var result = new OperationResult();
            try
            {
                lockoutService.Show(T("Removing package..."));
                result = await privilegedOperationService.RemovePackagesAsync([item.Package],
                    true, false, true);
            }
            catch (Exception e)
            {
                Console.WriteLine(e);
            }
            finally
            {
                if (result.Success)
                {
                    genericQuestionService.RaiseToastMessage(
                        new ToastMessageEventArgs(T("Package removed successfully")));
                    installedCheck.SetVisible(false);
                    downloadButton.SetVisible(true);
                    removeButton.SetVisible(false);
                }

                lockoutService.Hide();
            }
        };

        downloadButton.SetVisible(!item.IsInstalled);
        downloadButton.AddCssClass("suggested-action");
        downloadButton.SetValign(Align.Center);
        downloadButton.SetTooltipText(T("Install ") + item.Package);
        downloadButton.OnClicked += async (_, _) =>
        {
            var result = new OperationResult();
            try
            {
                lockoutService.Show(T("Installing package..."));
                result = await privilegedOperationService.InstallPackagesAsync([item.Package]);
            }
            catch (Exception e)
            {
                Console.WriteLine(e);
            }
            finally
            {
                if (result.Success)
                {
                    genericQuestionService.RaiseToastMessage(
                        new ToastMessageEventArgs(T("Package installed successfully")));
                    installedCheck.SetVisible(true);
                    downloadButton.SetVisible(false);
                    removeButton.SetVisible(true);
                }

                lockoutService.Hide();
            }
        };

        contentBox.Append(removeButton);
        contentBox.Append(downloadButton);

        var frame = Frame.New(null);
        frame.SetChild(contentBox);
        frame.Hexpand = true;
        frame.Halign = Align.Fill;
        frame.AddCssClass("card");

        sizeGroup.AddWidget(frame);
        flowBox.Append(frame);
    }
}