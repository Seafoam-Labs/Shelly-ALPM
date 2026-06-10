using PackageManager.Wire;
using Shelly.Utilities.Eventing;

namespace Shelly_CLI.Utility;

internal static class UiFrames
{
    public static void Info(string message, AlpmEvents kind = AlpmEvents.InformationalOutput) =>
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(kind, message));

    public static void Info(string message, AlpmEvents kind, string? packageName, int? currentIndex = null, int? totalCount = null) =>
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(kind, message, packageName, currentIndex, totalCount));

    public static void Error(string message) =>
        JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, message));

    public static void TxStart(string message) =>
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(AlpmEvents.TransactionStart, message));

    public static void TxFinish(bool ok, string completeMsg, string failedMsg) =>
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            ok ? AlpmEvents.TransactionDone : AlpmEvents.TransactionFailed,
            ok ? completeMsg : failedMsg));

    public static void TxDone(string completeMsg) =>
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            AlpmEvents.TransactionDone, completeMsg));

    public static void TxFailed(string failedMsg) =>
        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            AlpmEvents.TransactionFailed, failedMsg));

    public static void Frame<T>(T value) =>
        JsonPackFrame.WriteToStdout(value);
}
