using Gtk;
using Shelly.Gtk.Windows.Dialog;
using Shelly.Gtk.UiModels;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Services;

public class PkgBuildService : IPkgBuildService
{
    private readonly HttpClient _httpClient = new();

    public async Task ShowPreviewAsync(Overlay parentOverlay, string packageName, IGenericQuestionService questionService)
    {
        try
        {
            string url = $"https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h={packageName}";
            using var response = await _httpClient.GetAsync(url);

            if (!response.IsSuccessStatusCode)
            {
                GLib.Functions.IdleAdd(0, () => {
                    questionService.RaiseToastMessage(new ToastMessageEventArgs(T("PKGBUILD for '{0}' not found.", packageName)));
                    return false;
                });      
                return;
            }
            
            var content = await response.Content.ReadAsStringAsync();
            
            if (string.IsNullOrWhiteSpace(content))
            {
                GLib.Functions.IdleAdd(0, () => {
                    questionService.RaiseToastMessage(new ToastMessageEventArgs(T("The PKGBUILD is empty.")));
                    return false;
                });                
                return;
            }
            
            GLib.Functions.IdleAdd(0, () => 
            {
                var args = new PackageBuildEventArgs(T("PKGBUILD: {0}", packageName), content);
            
                PkgbuildPreview.ShowPackageBuildPreview(parentOverlay, args, questionService);
            
                return false; 
            });
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Erro no serviço: {ex.Message}");
        }
    }
}
