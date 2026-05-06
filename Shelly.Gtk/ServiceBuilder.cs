using Microsoft.Extensions.DependencyInjection;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.FlatHub;
using Shelly.Gtk.Services.Icons;
using Shelly.Gtk.Services.TrayServices;
using Shelly.Gtk.Windows;
using Shelly.Gtk.Windows.AUR;
using Shelly.Gtk.Windows.Dialog;
using Shelly.Gtk.Windows.Flatpak;
using Shelly.Gtk.Windows.Packages;

namespace Shelly.Gtk;

public static class ServiceBuilder
{
    public static ServiceProvider CreateDependencyInjection(ServiceCollection collection)
    {
        collection.AddSingleton<IPrivilegedOperationService, PrivilegedOperationService>();
        collection.AddSingleton<IUnprivilegedOperationService, UnprivilegedOperationService>();
        collection.AddSingleton<ICredentialManager, CredentialManager>();
        collection.AddSingleton<IAlpmEventService, AlpmEventService>();
        collection.AddSingleton<IConfigService, ConfigService>();
        collection.AddSingleton<IPkgBuildService, PkgBuildService>();
        collection.AddSingleton<IGenericQuestionService, GenericQuestionService>();
        collection.AddSingleton<IDirtyService, DirtyService>();
        collection.AddSingleton<ILockoutService, LockoutService>();
        collection.AddSingleton<IIconResolverService, IconResolverService>();
        collection.AddSingleton<IArchNewsService, ArchNewsService>();
        collection.AddSingleton<IOperationLogService, OperationLogService>();
        collection.AddSingleton<IPackageUpdateNotifier, PackageUpdateNotifier>();
        collection.AddSingleton<IIConDownloadService, IconDownloadService>();
        collection.AddScoped<IUpdateService, GitHubUpdateService>();
        collection.AddScoped<ITrayDbus, TrayDBus>();
        collection.AddScoped<IFlatHubApiService, FlatHubApiService>();
        collection.AddTransient<FlatpakRemove>();
        collection.AddTransient<AurInstall>();
        collection.AddTransient<AurUpdate>();
        collection.AddTransient<AurRemove>();
        collection.AddTransient<FlatpakInstall>();
        collection.AddTransient<FlatpakUpdate>();
        collection.AddTransient<PackageManagement>();
        collection.AddTransient<PackageUpdate>();
        collection.AddTransient<PackageInstall>();
        collection.AddTransient<ShellySearch>();
        collection.AddTransient<Settings>();
        collection.AddTransient<PasswordDialog>();
        collection.AddSingleton<LockoutDialog>();
        collection.AddTransient<AlpmEventDialog>();
        collection.AddTransient<AppImage>();
        collection.AddTransient<WebWindow>();
        collection.AddTransient<SetupWindow>();
        return collection.BuildServiceProvider();
    }
}