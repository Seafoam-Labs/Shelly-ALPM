using System.Diagnostics;

namespace Shelly.Gtk.Services;

public class CredentialManager : ICredentialManager
{
    public const string NoPassword = "NOPASSWORD67";
    private const double TimeToLive = 9;
    private readonly Lock _lock = new();
    private bool _isValidated;
    private TaskCompletionSource<bool>? _pendingRequest;
    private string? _storedPassword;
    private DateTime _storedTime;

    public bool HasStoredCredentials
    {
        get
        {
            lock (_lock)
            {
                return !string.IsNullOrEmpty(_storedPassword);
            }
        }
    }

    public bool IsValidated
    {
        get
        {
            lock (_lock)
            {
                return _isValidated;
            }
        }
    }

    public bool IsExpired()
    {
        lock (_lock)
        {
            if (!((DateTime.UtcNow - _storedTime).TotalMinutes > TimeToLive)) return false;
            _storedPassword = "";
            _isValidated = false;
            return true;
        }
    }

    public void StorePassword(string password)
    {
        lock (_lock)
        {
            _storedPassword = password;
            _isValidated = false;
            _storedTime = DateTime.UtcNow;
        }
    }

    public string? GetPassword()
    {
        lock (_lock)
        {
            return _storedPassword;
        }
    }

    public void ClearCredentials()
    {
        lock (_lock)
        {
            // Overwrite the password in memory before clearing
            if (_storedPassword != null)
            {
                var length = _storedPassword.Length;
                _storedPassword = new string('\0', length);
            }

            _storedPassword = null;
            _isValidated = false;
        }
    }

    public void MarkAsValidated()
    {
        lock (_lock)
        {
            _isValidated = true;
        }
    }

    public void MarkAsInvalid()
    {
        lock (_lock)
        {
            _isValidated = false;
            // Clear invalid credentials
            if (_storedPassword != null)
            {
                var length = _storedPassword.Length;
                _storedPassword = new string('\0', length);
            }

            _storedPassword = null;
        }
    }

    public event EventHandler<CredentialRequestEventArgs>? CredentialRequested;

    public async Task<bool> RequestCredentialsAsync(string reason)
    {
        TaskCompletionSource<bool> tcs;
        var shouldRaiseEvent = false;

        lock (_lock)
        {
            // If we already have validated credentials, return immediately
            if (HasStoredCredentials) return true;

            if (IsAccountPasswordless(Environment.UserName) || IsSudoPasswordless() || IsYubiKeyConfigured())
            {
                _isValidated = true;
                _storedPassword = NoPassword;
                return true;
            }

            // If there's already a pending request, return its task
            if (_pendingRequest != null)
            {
                tcs = _pendingRequest;
            }
            else
            {
                // Create a new completion source for this request
                _pendingRequest = new TaskCompletionSource<bool>();
                tcs = _pendingRequest;
                shouldRaiseEvent = true;
            }
        }

        // Raise the event to request credentials from the UI
        if (shouldRaiseEvent)
            CredentialRequested?.Invoke(this, new CredentialRequestEventArgs(reason));

        // Wait for the UI to complete the request
        return await tcs.Task;
    }

    public async Task CompleteCredentialRequestAsync(bool success)
    {
        TaskCompletionSource<bool>? tcs;

        lock (_lock)
        {
            tcs = _pendingRequest;
        }

        if (success)
        {
            var isValid = await ValidateInputCredentials();
            if (isValid)
            {
                lock (_lock)
                {
                    _pendingRequest = null;
                }

                tcs?.TrySetResult(true);
            }
        }
        else
        {
            lock (_lock)
            {
                _pendingRequest = null;
            }

            tcs?.TrySetResult(false);
        }
    }

    public async Task<bool> ValidateInputCredentials()
    {
        var password = GetPassword();
        var username = Environment.UserName;

        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = "su",
            Arguments = $"-c true {username}",
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        try
        {
            process.Start();

            // Pipe the password to su
            await process.StandardInput.WriteLineAsync(password);
            await process.StandardInput.FlushAsync();
            process.StandardInput.Close();

            await process.WaitForExitAsync();

            if (process.ExitCode == 0)
            {
                Console.WriteLine("Credentials verified successfully via su.");
                MarkAsValidated();
                return true;
            }

            await Console.Error.WriteLineAsync("Authentication failed via su. Clearing credentials.");
            MarkAsInvalid();
            return false;
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync($"Error during authentication check: {ex.Message}");
        }

        return false;
    }

    /// <summary>
    ///     Verifies sudo execution can  work without needing to validate the password
    /// </summary>
    /// <returns>If sudo is passwordless</returns>
    private static bool IsSudoPasswordless()
    {
        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = "sudo",
                Arguments = "-n true", // -n is 'non-interactive'
                UseShellExecute = false,
                CreateNoWindow = true
            };
            process.Start();
            process.WaitForExit();
            return process.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsYubiKeyConfigured()
    {
        try
        {
            const string pamSudoPath = "/etc/pam.d/sudo";
            if (File.Exists(pamSudoPath))
            {
                var content = File.ReadAllText(pamSudoPath);
                return content.Contains("pam_u2f.so");
            }
        }
        catch
        {
            /* ignore */
        }

        return false;
    }

    private static bool IsAccountPasswordless(string username)
    {
        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = "passwd",
                Arguments = $"--status {username}",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                CreateNoWindow = true
            };
            process.Start();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit();

            // Output format: "username NP ..." where NP = No Password
            // "P" = has password, "L" = locked, "NP" = no password
            var parts = output.Split(' ', '\t', StringSplitOptions.None);
            if (parts is [_, "NP", ..])
                return true;
        }
        catch
        {
            /* ignore */
        }

        return false;
    }
}