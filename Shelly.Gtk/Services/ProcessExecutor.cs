using System.Diagnostics;
using System.Text;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services.Wire;

namespace Shelly.Gtk.Services;

public class ProcessExecutor(ICredentialManager credentialManager) : IProcessExecutor
{
    private readonly string _cliPath = CliPathResolver.FindCliPath();

    public async Task<OperationResult> RunShellyCommandAsync(string[] args)
    {
        return await RunSystemCommandAsync(_cliPath, [.. args, "--ui-mode"]);
    }

    public async Task<OperationResult> RunShellyInteractiveCommandAsync(
        string[] args,
        IAlpmEventService eventService,
        ILockoutService lockoutService,
        IGenericQuestionService questionService)
    {
        using var process = CreateProcess(_cliPath, true, [.. args, "--ui-mode"]);
        LogCommand(_cliPath, process.StartInfo.ArgumentList);

        var outputBuilder = new StringBuilder();
        var errorBuilder = new StringBuilder();
        StreamWriter? stdinWriter = null;

        // Prevent stdin writes racing with shutdown while async callbacks are still in-flight.
        var stdinLock = new SemaphoreSlim(1, 1);
        var stdinClosed = false;
        var pendingCallbacks = 0;
        var allCallbacksDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        async Task SafeWriteAsync(string value)
        {
            await stdinLock.WaitAsync();
            try
            {
                if (!stdinClosed && stdinWriter != null)
                {
                    await stdinWriter.WriteLineAsync(value);
                    await stdinWriter.FlushAsync();
                }
            }
            catch (ObjectDisposedException)
            {
                // ignored
            }
            finally
            {
                stdinLock.Release();
            }
        }

        var eventRouter = new EventRouter(eventService, lockoutService);

        process.OutputDataReceived += async (_, e) =>
        {
            if (e.Data == null) return;

            outputBuilder.AppendLine(e.Data);

            if (JsonPackFrame.TryExtractPayload(e.Data, out var b64))
            {
                if (eventRouter.TryDispatch(b64)) return;

                Interlocked.Increment(ref pendingCallbacks);
                try
                {
                    await QuestionRouter.TryDispatchAsync(b64, SafeWriteAsync, questionService, eventService);
                }
                catch (Exception ex)
                {
                    await Console.Error.WriteLineAsync($"QuestionRouter error: {ex.Message}");
                }
                finally
                {
                    if (Interlocked.Decrement(ref pendingCallbacks) == 0)
                        allCallbacksDone.TrySetResult();
                }

                return;
            }

            Console.WriteLine(e.Data);
        };

        process.ErrorDataReceived += async (_, e) =>
        {
            if (e.Data == null) return;
            errorBuilder.AppendLine(e.Data);
            await Console.Error.WriteLineAsync(e.Data);
        };

        try
        {
            process.Start();
            stdinWriter = process.StandardInput;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            await process.WaitForExitAsync();

            if (Volatile.Read(ref pendingCallbacks) > 0)
                await Task.WhenAny(allCallbacksDone.Task, Task.Delay(TimeSpan.FromMinutes(2)));

            await stdinLock.WaitAsync();
            try
            {
                stdinClosed = true;
                stdinWriter.Close();
            }
            finally
            {
                stdinLock.Release();
            }

            return new OperationResult
            {
                Success = process.ExitCode == 0,
                Output = outputBuilder.ToString(),
                Error = errorBuilder.ToString(),
                ExitCode = process.ExitCode
            };
        }
        catch (Exception ex)
        {
            return ErrorResult(ex);
        }
    }

    public async Task<OperationResult> RunSystemCommandAsync(string command, string[] args)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(command);

        using var process = CreateProcess(command, false, args);
        LogCommand(command, process.StartInfo.ArgumentList);

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

        LogCommand(process.StartInfo.FileName, process.StartInfo.ArgumentList);

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
        LogCommand(process.StartInfo.FileName, process.StartInfo.ArgumentList);

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

    private static void LogCommand(string cmd, IEnumerable<string> args)
    {
        Console.WriteLine($"Executing command: {cmd} {string.Join(" ", args)}");
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