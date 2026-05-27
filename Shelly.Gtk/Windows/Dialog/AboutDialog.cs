using System.Reflection;
using Gtk;
using Shelly.Gtk.UiModels;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Windows.Dialog;

public class ShellyAboutDialog(Overlay overlay)
{
    public void OpenAboutDialog()
    {
        try
        {
            var dialog = AboutDialog.New();

            dialog.ProgramName = "Shelly";
            dialog.Version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(4) ?? "0.0.0.0";
            dialog.Comments = T("Shelly is an Arch Linux package manager");
            dialog.Copyright = $"© {DateTime.Now.Year} Seafoam Labs";

            dialog.LicenseType = License.Gpl30;
            dialog.WrapLicense = true;

            dialog.Website = "https://www.seafoam-labs.org/";
            dialog.WebsiteLabel = T("Seafoam Labs Website");
            
            dialog.AddCreditSection(T("Project Leads"), ["Zoey Bauer", "Caroline Snyder"]);
            dialog.AddCreditSection(T("Maintainers"), [
                "Vinícius Fonseca",
                "Anton Ždanov"
            ]);

            dialog.LogoIconName  = "shelly"; 
            
            dialog.SetTransientFor(overlay.GetRoot() as Window);
            dialog.Present();
            dialog.Modal = true;
            
            var focusController = EventControllerFocus.New();
            focusController.OnLeave += (_, _) => dialog.Destroy();
            dialog.AddController(focusController);
            dialog.Present();

        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load about dialog {e}");
        }
    }
}