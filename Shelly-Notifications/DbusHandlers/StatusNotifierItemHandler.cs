using Shelly_Notifications.Services;
using Tmds.DBus.Protocol;

namespace Shelly_Notifications.DbusHandlers;

internal class StatusNotifierItemHandler : IPathMethodHandler
{
    public string Path => "/StatusNotifierItem";
    
    public bool HandlesChildPaths => false; 

    public ValueTask HandleMethodAsync(MethodContext context)
    {
        var request = context.Request;
        try
        {
            if (request.Interface.SequenceEqual("org.kde.StatusNotifierItem"u8) ||
                request.Interface.SequenceEqual("org.freedesktop.StatusNotifierItem"u8))
            {
                if (request.Member.SequenceEqual("Activate"u8))
                {
                    context.Reply(context.CreateReplyWriter("").CreateMessage());
                    AppRunner.LaunchAppIfNotRunning("");
                    Console.WriteLine("[DEBUG_LOG] Tray icon left-clicked (Activate).");
                    return new ValueTask(OnActivateAsync(0, 0));
                }

                if (request.Member.SequenceEqual("ContextMenu"u8))
                {
                    context.Reply(context.CreateReplyWriter("").CreateMessage());
                    return new ValueTask(OnContextMenuAsync(0, 0));
                }
            }

            if (request.Interface.SequenceEqual("org.freedesktop.DBus.Properties"u8))
            {
                if (request.Member.SequenceEqual("GetAll"u8))
                {
                    var reader = request.GetBodyReader();
                    var interfaceName = reader.ReadString();
                    if (interfaceName == "org.kde.StatusNotifierItem" ||
                        interfaceName == "org.freedesktop.StatusNotifierItem")
                    {
                        using (var writer = context.CreateReplyWriter("a{sv}"))
                        {
                            var dict = new Dictionary<string, VariantValue>
                            {
                                { "Category", (VariantValue)"ApplicationStatus" },
                                { "Id", (VariantValue)"Shelly" },
                                { "Title", (VariantValue)"Shelly Notifications" },
                                { "Status", (VariantValue)"Active" },
                                { "IconName", (VariantValue)"shelly" },
                                { "IconThemePath", (VariantValue)string.Empty },
                                { "ItemIsMenu", (VariantValue)false },
                                { "Menu", (VariantValue)new ObjectPath("/MenuBar") }
                            };
                            writer.WriteDictionary(dict);
                            context.Reply(writer.CreateMessage());
                        }

                        return ValueTask.CompletedTask;
                    }
                }

                if (request.Member.SequenceEqual("Get"u8))
                {
                    var reader = request.GetBodyReader();
                    var interfaceName = reader.ReadString();
                    var propertyName = reader.ReadString();
                    if (interfaceName == "org.kde.StatusNotifierItem" ||
                        interfaceName == "org.freedesktop.StatusNotifierItem")
                    {
                        using (var writer = context.CreateReplyWriter("v"))
                        {
                            switch (propertyName)
                            {
                                case "Category": writer.WriteVariant("ApplicationStatus"); break;
                                case "Id": writer.WriteVariant("Shelly"); break;
                                case "Title": writer.WriteVariant("Shelly Notifications"); break;
                                case "Status": writer.WriteVariant("Active"); break;
                                case "IconName": writer.WriteVariant("shelly"); break;
                                case "IconThemePath": writer.WriteVariant(string.Empty); break;
                                case "ItemIsMenu": writer.WriteVariant(false); break;
                                case "Menu": writer.WriteVariant(new ObjectPath("/MenuBar")); break;
                                default:
                                    context.ReplyError("org.freedesktop.DBus.Error.InvalidArgs", "Unknown property");
                                    return ValueTask.CompletedTask;
                            }

                            context.Reply(writer.CreateMessage());
                        }

                        return ValueTask.CompletedTask;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Error] StatusNotifierItemHandler error: {ex}");
        }

        return ValueTask.CompletedTask;
    }

    private static Task OnContextMenuAsync(int x, int y) => Task.CompletedTask;

    private static Task OnActivateAsync(int x, int y) => Task.CompletedTask;
}