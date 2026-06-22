namespace Shelly.Gtk.Services;

public interface IProcessExecutor
{
    Task<OperationResult> RunShellyCommandAsync(string[] args);
    Task<OperationResult> RunSystemCommandAsync(string command, string[] args);
    Task<OperationResult> RunPrivilegedSystemCommandAsync(string description, string[] args);
}