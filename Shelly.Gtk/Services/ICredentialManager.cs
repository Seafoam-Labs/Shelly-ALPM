namespace Shelly.Gtk.Services;

public interface ICredentialManager
{
    /// <summary>
    ///     Gets whether a password is currently stored in the session.
    /// </summary>
    bool HasStoredCredentials { get; }

    /// <summary>
    ///     Gets whether the stored credentials have been validated.
    /// </summary>
    bool IsValidated { get; }

    /// <summary>
    ///     Gets whether the stored credentials are expired.
    /// </summary>
    bool IsExpired();

    /// <summary>
    ///     Stores the password for the current session.
    /// </summary>
    void StorePassword(string password);

    /// <summary>
    ///     Gets the stored password. Returns null if no password is stored.
    /// </summary>
    string? GetPassword();

    /// <summary>
    ///     Clears the stored password from memory.
    /// </summary>
    void ClearCredentials();

    /// <summary>
    ///     Marks the stored credentials as validated (successful sudo operation).
    /// </summary>
    void MarkAsValidated();

    /// <summary>
    ///     Marks the stored credentials as invalid (failed sudo operation).
    /// </summary>
    void MarkAsInvalid();

    /// <summary>
    ///     Event raised when credentials are needed.
    /// </summary>
    event EventHandler<CredentialRequestEventArgs>? CredentialRequested;

    /// <summary>
    ///     Requests credentials from the user. Returns true if credentials were provided.
    /// </summary>
    Task<bool> RequestCredentialsAsync(string reason);

    /// <summary>
    ///     Completes a pending credential request.
    /// </summary>
    Task CompleteCredentialRequestAsync(bool success);

    /// <summary>
    ///     Validates the stored credentials with sudo su.
    /// </summary>
    Task<bool> ValidateInputCredentials();
}

public class CredentialRequestEventArgs(string reason) : EventArgs
{
    public string Reason { get; } = reason;
}