namespace Shelly.Gtk.Services;

public interface IProcessExecutor
{
    Task<OperationResult> RunShellyCliCommandAsync(string[] args);
    Task<OperationResult> RunPrivilegedSystemCommandAsync(string description, string[] args);
}