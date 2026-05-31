using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
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
            
            var sourceFiles = await FetchSourceFilesAsync(content, packageName);

            GLib.Functions.IdleAdd(0, () => 
            {
                var args = new PackageBuildEventArgs(T("PKGBUILD: {0}", packageName), content, sourceFiles);
            
                var parent = (Gio.Application.GetDefault() as Application)?.GetActiveWindow();
                PkgbuildPreview.ShowPackageBuildPreview(parent, args);
            
                return false; 
            });
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Erro no serviço: {ex.Message}");
        }
    }

    private static readonly string[] LocalSourceExtensions =
    [
        ".sh", ".bash", ".install", ".patch", ".diff", ".desktop",
        ".py", ".pl", ".rb", ".service", ".conf", ".cfg", ".hook"
    ];

    private async Task<Dictionary<string, string>> FetchSourceFilesAsync(string pkgbuild, string packageName)
    {
        var sourceFiles = new Dictionary<string, string>();
        try
        {
            foreach (var fileName in ExtractLocalSourceFiles(pkgbuild))
            {
                var url = $"https://aur.archlinux.org/cgit/aur.git/plain/{Uri.EscapeDataString(fileName)}?h={packageName}";
                using var response = await _httpClient.GetAsync(url);
                if (!response.IsSuccessStatusCode)
                    continue;

                var fileContent = await response.Content.ReadAsStringAsync();
                if (!string.IsNullOrWhiteSpace(fileContent))
                    sourceFiles[fileName] = fileContent;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Erro ao buscar arquivos de origem: {ex.Message}");
        }

        return sourceFiles;
    }

    private static IEnumerable<string> ExtractLocalSourceFiles(string pkgbuild)
    {
        var files = new List<string>();
        var match = Regex.Match(pkgbuild, @"source\s*=\s*\(([^)]*)\)", RegexOptions.Singleline);
        if (!match.Success)
            return files;

        var body = match.Groups[1].Value;
        var tokens = Regex.Matches(body, "\"([^\"]*)\"|'([^']*)'|(\\S+)");
        foreach (Match token in tokens)
        {
            var entry = token.Groups[1].Success ? token.Groups[1].Value
                : token.Groups[2].Success ? token.Groups[2].Value
                : token.Groups[3].Value;
            entry = entry.Trim();
            if (entry.Length == 0)
                continue;

            var idx = entry.IndexOf("::", StringComparison.Ordinal);
            var name = idx >= 0 ? entry[..idx].Trim() : entry;
            var location = idx >= 0 ? entry[(idx + 2)..].Trim() : entry;

            if (location.Contains("://"))
                continue;

            if (string.IsNullOrWhiteSpace(name) || name.Contains('$'))
                continue;

            var ext = Path.GetExtension(name).ToLowerInvariant();
            if (!LocalSourceExtensions.Contains(ext))
                continue;

            if (!files.Contains(name))
                files.Add(name);
        }

        return files;
    }
}
