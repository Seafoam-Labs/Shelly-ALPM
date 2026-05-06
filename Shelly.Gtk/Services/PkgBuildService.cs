using Gtk;
using Shelly.Gtk.Windows.Dialog;
using Shelly.Gtk.UiModels;

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
                    questionService.RaiseToastMessage(new ToastMessageEventArgs($"PKGBUILD for '{packageName}' not found."));
                    return false;
                });      
                return;
            }
            
            var content = await response.Content.ReadAsStringAsync();
            
            if (string.IsNullOrWhiteSpace(content))
            {
                GLib.Functions.IdleAdd(0, () => {
                    questionService.RaiseToastMessage(new ToastMessageEventArgs("The PKGBUILD is empty."));
                    return false;
                });                
                return;
            }
            
            GLib.Functions.IdleAdd(0, () => 
            {
                var args = new PackageBuildEventArgs($"PKGBUILD: {packageName}", content);
            
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