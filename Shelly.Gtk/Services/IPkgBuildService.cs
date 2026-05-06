using System.Threading.Tasks;
using Gtk; 

namespace Shelly.Gtk.Services;

public interface IPkgBuildService
{
    Task ShowPreviewAsync(Overlay overlay, string packageName, IGenericQuestionService questionService);
}