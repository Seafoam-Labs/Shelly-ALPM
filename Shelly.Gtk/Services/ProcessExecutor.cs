using System.Collections.ObjectModel;
using System.Diagnostics;
using Shelly.Gtk.Helpers;

namespace Shelly.Gtk.Services;

public class ProcessExecutor(ICredentialManager credentialManager) : IProcessExecutor
{
    private readonly string _cliPath = CliPathResolver.FindCliPath();

    public async Task<OperationResult> RunShellyCliCommandAsync(string[] args)
    {
        using var process = CreateProcess(_cliPath, false, args);
        process.StartInfo.ArgumentList.Add("--ui-mode");
        LogCommand(_cliPath, process.StartInfo.ArgumentList);

        try
        {
            process.Start();
            return await ReadResultAsync(process);
        }
        catch (Exception ex)
        {
            return ErrorResult(ex);
        }
    }

    public async Task<OperationResult> RunPrivilegedSystemCommandAsync(string description, string[] args)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(description);

        var chosen = DetectEscalatorAsync();

        return chosen switch
        {
            PrivilegeEscalator.Sudo => await RunSudoAsync(description, args),
            PrivilegeEscalator.Pkexec => await RunPkexecAsync(args),
            _ => new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = $"No privilege escalation tool available: {chosen}",
                ExitCode = -1
            }
        };
    }

    private static PrivilegeEscalator DetectEscalatorAsync()
    {
        if (IsCommandOnPath("pkexec")) return PrivilegeEscalator.Pkexec;
        if (IsCommandOnPath("sudo")) return PrivilegeEscalator.Sudo;
        return PrivilegeEscalator.None;
    }

    private static bool IsCommandOnPath(string command)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(command)) return false;

            var path = Environment.GetEnvironmentVariable("PATH");
            if (string.IsNullOrWhiteSpace(path)) return false;

            return path
                .Split(Path.PathSeparator)
                .Select(dir => Path.Combine(dir, command))
                .Any(File.Exists);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error checking if command {command} is available: {ex.Message}");
            return false;
        }
    }

    private async Task<OperationResult> RunSudoAsync(string description, string[] args)
    {
        var hasCredentials = await credentialManager.RequestCredentialsAsync(description);
        if (!hasCredentials) return AuthCancelledResult();

        var password = credentialManager.GetPassword();
        var isPasswordless = password == CredentialManager.NoPassword;

        using var process = CreateProcess("sudo", true, args);
        process.StartInfo.ArgumentList.Insert(0, "-k");
        if (!isPasswordless) process.StartInfo.ArgumentList.Insert(0, "-S");

        LogCommand("sudo", process.StartInfo.ArgumentList);

        try
        {
            process.Start();

            if (!isPasswordless)
            {
                await process.StandardInput.WriteLineAsync(password);
                await process.StandardInput.FlushAsync();
                process.StandardInput.Close();
            }

            return await ReadResultAsync(process);
        }
        catch (Exception ex)
        {
            return ErrorResult(ex);
        }
    }

    private static async Task<OperationResult> RunPkexecAsync(string[] args)
    {
        using var process = CreateProcess("pkexec", false, args);
        LogCommand("pkexec", process.StartInfo.ArgumentList);

        try
        {
            process.Start();
            return await ReadResultAsync(process);
        }
        catch (Exception ex)
        {
            return ErrorResult(ex);
        }
    }

    private static Process CreateProcess(string path, bool redirectInput, string[] args)
    {
        var process = new Process();
        process.StartInfo = new ProcessStartInfo(path)
        {
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardInput = redirectInput,
            RedirectStandardOutput = true,
            UseShellExecute = false
        };

        foreach (var arg in args)
            process.StartInfo.ArgumentList.Add(arg);

        return process;
    }

    private static void LogCommand(string path, Collection<string> arguments)
    {
        Console.WriteLine($"Executing command: {path} {string.Join(" ", arguments)}");
    }

    private static async Task<OperationResult> ReadResultAsync(Process process)
    {
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();

        await Task.WhenAll(outputTask, errorTask);
        await process.WaitForExitAsync();

        var output = await outputTask;
        var error = await errorTask;

        if (!string.IsNullOrEmpty(error))
            await Console.Error.WriteLineAsync(error);

        return new OperationResult
        {
            Success = process.ExitCode == 0,
            Output = output,
            Error = error,
            ExitCode = process.ExitCode
        };
    }

    private static OperationResult AuthCancelledResult()
    {
        return new OperationResult
        {
            Success = false,
            Output = string.Empty,
            Error = "Authentication cancelled by user.",
            ExitCode = -1
        };
    }

    private static OperationResult ErrorResult(Exception ex)
    {
        return new OperationResult
        {
            Success = false,
            Output = string.Empty,
            Error = ex.Message,
            ExitCode = -1
        };
    }

    private enum PrivilegeEscalator
    {
        None,
        Sudo,
        Pkexec
    }
}