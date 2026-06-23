namespace Shelly.Gtk.Services;

public interface IProcessExecutor
{
    Task<OperationResult> RunShellyCommandAsync(string[] args);

    Task<OperationResult> RunShellyInteractiveCommandAsync(string[] args);

    Task<OperationResult> RunPrivilegedShellyCommandAsync(string description, string[] args);

    Task<OperationResult> RunSystemCommandAsync(string command, string[] args);

    Task<OperationResult> RunPrivilegedSystemCommandAsync(string description, string[] args);
}