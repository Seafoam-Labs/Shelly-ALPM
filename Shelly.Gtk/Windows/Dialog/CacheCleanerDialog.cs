using System.Text.RegularExpressions;
using Gtk;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Windows.Dialog;

public partial class CacheCleanerDialog(
    IGenericQuestionService genericQuestionService,
    IPrivilegedOperationService privilegedOperationService,
    ILockoutService lockoutService,
    Overlay overlay)
{
    public void OpenCacheCleanDialog()
    {
        try
        {
            const string cacheDir = "/var/cache/pacman/pkg";
            if (!Directory.Exists(cacheDir))
            {
                var toastArgs = new ToastMessageEventArgs(T("Cache directory does not exist"));
                genericQuestionService.RaiseToastMessage(toastArgs);
                return;
            }

            var dialogEventArgs = new GenericDialogEventArgs(Box.NewWithProperties([]));

            var content = CacheCleanDialog.BuildContent(
                cacheDir,
                onClean: (keep, uninstalledOnly) =>
                {
                    dialogEventArgs.SetResponse(true);
                    _ = ExecuteCacheClean(keep, uninstalledOnly);
                },
                onCancel: () => dialogEventArgs.SetResponse(false)
            );

            GenericOverlay.ShowGenericOverlay(overlay, content, dialogEventArgs, 650, 550);
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
    }

    private async Task ExecuteCacheClean(int keep, bool uninstalledOnly)
    {
        try
        {
            lockoutService.Show(T("Cleaning package cache..."));
            var result = await privilegedOperationService.RunCacheCleanAsync(keep, uninstalledOnly);

            string message;
            if (result.Success)
            {
                var output = StripAnsiAndMarkup(result.Output);
                message = string.IsNullOrWhiteSpace(output)
                    ? T("Package cache cleaned successfully")
                    : output;
            }
            else
            {
                message = T("Cache clean failed: {0}", result.Error);
            }

            var toastArgs = new ToastMessageEventArgs(message);
            genericQuestionService.RaiseToastMessage(toastArgs);
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    private static string StripAnsiAndMarkup(string input)
    {
        var noAnsi = StripAnsi().Replace(input, "");
        var noMarkup = StripMarkup().Replace(noAnsi, "");
        return noMarkup.Trim();
    }

    [GeneratedRegex(@"\x1B\[[^@-~]*[@-~]")]
    private static partial Regex StripAnsi();
    [GeneratedRegex(@"\[\/?[a-zA-Z0-9_ ]*\]")]
    private static partial Regex StripMarkup();
}