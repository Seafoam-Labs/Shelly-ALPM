using System.Diagnostics;
using System.Text;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services.Wire;
using Tmds.DBus.Protocol;

namespace Shelly.Gtk.Services;

public sealed class ProcessExecutor(
    ICredentialManager credentialManager,
    IAlpmEventService eventService,
    ILockoutService lockoutService,
    IGenericQuestionService questionService) : IProcessExecutor
{
    private readonly string _cliPath = CliPathResolver.FindCliPath();
    private readonly Lazy<Task<PrivilegeEscalator>> _escalator = new(DetectEscalatorAsync);

    public async Task<OperationResult> RunShellyCommandAsync(string[] args)
    {
        return await RunSystemCommandAsync(_cliPath, [.. args, "--ui-mode"]);
    }

    public async Task<OperationResult> RunShellyInteractiveCommandAsync(string[] args)
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

    public async Task<OperationResult> RunPrivilegedShellyCommandAsync(string description, string[] args)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(description);

        var chosen = await _escalator.Value;
        return chosen switch
        {
            PrivilegeEscalator.Pkexec => await RunPrivilegedShellyPkexecAsync(args),
            PrivilegeEscalator.Sudo => await RunPrivilegedShellySudoAsync(description, args),
            _ => new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = $"No privilege escalation tool available: {chosen}",
                ExitCode = -1
            }
        };
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

        var chosen = await _escalator.Value;
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

    private async Task<OperationResult> RunPrivilegedShellySudoAsync(string description, string[] args)
    {
        var hasCredentials = await credentialManager.RequestCredentialsAsync(description);
        if (!hasCredentials) return AuthCancelledResult();

        var password = credentialManager.GetPassword();
        if (string.IsNullOrEmpty(password))
            return new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = "No password available.",
                ExitCode = -1
            };

        var isPasswordless = password == CredentialManager.NoPassword;

        var fullArgs = new List<string>();
        if (!isPasswordless) fullArgs.Add("-S");
        fullArgs.Add("-k");
        fullArgs.Add(_cliPath);
        fullArgs.AddRange(args.Where(arg => !string.IsNullOrWhiteSpace(arg)));
        fullArgs.Add("--ui-mode");

        var result = await RunPrivilegedShellyAsync("sudo", fullArgs.ToArray(), isPasswordless ? null : password, true);

        if (result.Success)
        {
            credentialManager.MarkAsValidated();
            return result;
        }

        var errorOutput = result.Error;
        if (errorOutput.Contains("incorrect password") ||
            errorOutput.Contains("Sorry, try again") ||
            errorOutput.Contains("Authentication failure") ||
            (result.ExitCode == 1 && errorOutput.Contains("sudo")))
            credentialManager.MarkAsInvalid();

        return result;
    }

    private async Task<OperationResult> RunPrivilegedShellyPkexecAsync(string[] args)
    {
        var fullArgs = new List<string> { _cliPath };
        fullArgs.AddRange(args.Where(arg => !string.IsNullOrWhiteSpace(arg)));
        fullArgs.Add("--ui-mode");

        return await RunPrivilegedShellyAsync("pkexec", fullArgs.ToArray(), null, false);
    }

    private static async Task<PrivilegeEscalator> DetectEscalatorAsync()
    {
        if (IsCommandOnPath("pkexec") && await IsPolkitAvailableAsync()) return PrivilegeEscalator.Pkexec;
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

    private static async Task<bool> IsPolkitAvailableAsync()
    {
        using DBusConnection systemConnection = new(DBusAddress.System!);
        await systemConnection.ConnectAsync();

        var services = await systemConnection.ListServicesAsync();
        return services.Contains("org.freedesktop.PolicyKit1");
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

    private async Task<OperationResult> RunPrivilegedShellyAsync(
        string escalatorCommand,
        string[] escalatorArgs,
        string? password,
        bool suppressSudoPasswordPrompt)
    {
        using var process = CreateProcess(escalatorCommand, true, escalatorArgs);
        LogCommand(process.StartInfo.FileName, process.StartInfo.ArgumentList);

        var outputBuilder = new StringBuilder();
        var errorBuilder = new StringBuilder();
        StreamWriter? stdinWriter = null;

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

        var restartNeedsReboot = false;
        var restartFailures = new List<(string Service, string Error)>();

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

            if (suppressSudoPasswordPrompt && (e.Data.Contains("[sudo]") || e.Data.Contains("password for"))) return;

            Interlocked.Increment(ref pendingCallbacks);
            try
            {
                Console.WriteLine(e.Data);
                if (e.Data.StartsWith("[ALPM_SCRIPTLET]"))
                {
                    var line = e.Data["[ALPM_SCRIPTLET]".Length..];
                    if (!string.IsNullOrEmpty(line)) lockoutService.ParseLog($"[SCRIPTLET] {line}");
                }
                else if (e.Data.StartsWith("[ALPM_HOOK]"))
                {
                    var line = e.Data["[ALPM_HOOK]".Length..];
                    if (!string.IsNullOrEmpty(line)) lockoutService.ParseLog($"[HOOK] {line}");
                }
                else if (e.Data.StartsWith("[Shelly][RESTART_REQUIRED]"))
                {
                    var payload = e.Data["[Shelly][RESTART_REQUIRED]".Length..];
                    if (payload == "reboot")
                        restartNeedsReboot = true;
                }
                else if (e.Data.StartsWith("[Shelly][RESTART_FAILED]"))
                {
                    var payload = e.Data["[Shelly][RESTART_FAILED]".Length..];
                    if (!payload.StartsWith("service:")) return;

                    var rest = payload["service:".Length..];
                    var parts = rest.Split('|', 2);
                    var svcName = parts[0];
                    var svcError = parts.Length > 1 ? parts[1] : "Unknown error";
                    restartFailures.Add((svcName, svcError));
                }
                else if (e.Data.StartsWith("[Shelly][DEBUG]"))
                {
                    // Debug messages - skip, don't forward to lockout dialog
                }
                else
                {
                    errorBuilder.AppendLine(e.Data);
                    await Console.Error.WriteLineAsync(e.Data);
                }
            }
            catch (Exception ex)
            {
                await Console.Error.WriteLineAsync($"Error processing stderr: {ex.Message}");
                errorBuilder.AppendLine(e.Data);
            }
            finally
            {
                if (Interlocked.Decrement(ref pendingCallbacks) == 0)
                    allCallbacksDone.TrySetResult();
            }
        };

        try
        {
            process.Start();
            stdinWriter = process.StandardInput;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            if (!string.IsNullOrEmpty(password))
            {
                await stdinWriter.WriteLineAsync(password);
                await stdinWriter.FlushAsync();
            }

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
                ExitCode = process.ExitCode,
                NeedsReboot = restartNeedsReboot,
                FailedServiceRestarts = restartFailures
            };
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