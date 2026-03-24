using Shelly_Notifications.Enums;
using Shelly_Notifications.Models;
using Shelly_Notifications.Services;
using Tmds.DBus.Protocol;

namespace Shelly_Notifications.DbusHandlers;

public class DBusMenuHandler(Connection connection) : IPathMethodHandler
{
    public string Path => "/MenuBar";
    public bool HandlesChildPaths => false;

    public event Action? OnExitRequested;

    private static readonly
        Dictionary<int, (string Label, string Type, bool Enabled, string icon, string subMenu, MenuEnum action)> Items =
            new()
            {
                [1] = ("Open Shelly", "standard", true, "shelly", "", MenuEnum.OpenShelly),
                [2] = ("Update Packages", "standard", true, "", "", MenuEnum.UpdatePackages),
                [3] = ("Check for Updates", "standard", true, "", "", MenuEnum.CheckForUpdates),
                [4] = ("Last check: Never", "standard", false, "", "", MenuEnum.LastTime),
                [5] = ("", "separator", false, "", "", MenuEnum.None),
                [98] = ("", "separator", false, "", "", MenuEnum.None),
                [99] = ("Exit", "standard", true, "", "", action: MenuEnum.Exit),
            };

    private const int SubmenuId = 6;

    private static readonly Dictionary<MenuEnum, List<int>> UpdatesSubmenuChildren = new();

    public ValueTask HandleMethodAsync(MethodContext context)
    {
        var req = context.Request;

        if (req.Interface.SequenceEqual("com.canonical.dbusmenu"u8))
        {
            if (req.Member.SequenceEqual("GetLayout"u8))
                return HandleGetLayout(context);
            if (req.Member.SequenceEqual("Event"u8))
                return HandleEvent(context);
            if (req.Member.SequenceEqual("EventGroup"u8))
                return HandleEventGroup(context);
            if (req.Member.SequenceEqual("GetGroupProperties"u8))
                return HandleGetGroupProperties(context);
            if (req.Member.SequenceEqual("GetProperty"u8))
                return HandleGetProperty(context);
            if (req.Member.SequenceEqual("AboutToShow"u8))
            {
                var reader = req.GetBodyReader();
                reader.ReadInt32();
                using var w = context.CreateReplyWriter("b");
                w.WriteBool(false);
                context.Reply(w.CreateMessage());
                return ValueTask.CompletedTask;
            }

            var member = System.Text.Encoding.UTF8.GetString(req.Member);
            Console.WriteLine($"[DBusMenu] Unhandled member: {member}");
            context.ReplyError("org.freedesktop.DBus.Error.UnknownMethod", $"Unknown: {member}");
            return ValueTask.CompletedTask;
        }

        if (req.Interface.SequenceEqual("org.freedesktop.DBus.Properties"u8))
        {
            if (req.Member.SequenceEqual("GetAll"u8))
            {
                using var w = context.CreateReplyWriter("a{sv}");
                w.WriteDictionary(new Dictionary<string, VariantValue>
                {
                    { "Version", (VariantValue)3u },
                    { "TextDirection", (VariantValue)"ltr" },
                    { "Status", (VariantValue)"normal" },
                    { "IconThemePath", (VariantValue)"" },
                });
                context.Reply(w.CreateMessage());
                return ValueTask.CompletedTask;
            }

            if (req.Member.SequenceEqual("Get"u8))
            {
                var reader = req.GetBodyReader();
                _ = reader.ReadString();
                var prop = reader.ReadString();
                using var w = context.CreateReplyWriter("v");
                switch (prop)
                {
                    case "Version": w.WriteVariantUInt32(3u); break;
                    case "TextDirection": w.WriteVariantString("ltr"); break;
                    case "Status": w.WriteVariantString("normal"); break;
                    default: w.WriteVariantString(""); break;
                }

                context.Reply(w.CreateMessage());
                return ValueTask.CompletedTask;
            }
        }

        context.ReplyError("org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
        return ValueTask.CompletedTask;
    }

    private VariantValue BuildMenuItemVariant(int id, string label, string type, bool enabled, string icon,
        string childrenDisplay)
    {
        Dict<string, VariantValue> props = new(new Dictionary<string, VariantValue>
        {
            { "label", label },
            { "type", type },
            { "enabled", enabled },
            { "visible", true },
            { "icon-name", icon },
            { "children-display", childrenDisplay }
        });

        VariantValue[] children = [];
        var submenuMap = new Dictionary<MenuEnum, Func<bool>>
        {
            { MenuEnum.StandardUpdate, () => id == GetIndexByAction(MenuEnum.StandardUpdate) },
            { MenuEnum.AurUpdate, () => id == GetIndexByAction(MenuEnum.AurUpdate) },
            { MenuEnum.FlatpakUpdate, () => id == GetIndexByAction(MenuEnum.FlatpakUpdate) },
        };

        if (childrenDisplay != "submenu")
            return VariantValue.Struct(
                VariantValue.Int32(id),
                props,
                VariantValue.ArrayOfVariant(children)
            );
        var match = submenuMap.FirstOrDefault(kvp => kvp.Value());
        if (match.Key != default)
            children = GetSubmenuChildren(match.Key);

        return VariantValue.Struct(
            VariantValue.Int32(id),
            props,
            VariantValue.ArrayOfVariant(children)
        );
    }

    private ValueTask HandleGetLayout(MethodContext context)
    {
        var reader = context.Request.GetBodyReader();
        var parentId = reader.ReadInt32();

        using var w = context.CreateReplyWriter("u(ia{sv}av)");
        w.WriteUInt32(1);

        w.WriteStructureStart();
        w.WriteInt32(parentId);

        int[] childrenIds = [];
        var childrenDisplayValue = "";

        MenuEnum action;

        if (parentId == 0)
        {
            childrenIds = Items.Keys.Where(k => k < 100).OrderBy(k => k).ToArray();
            childrenDisplayValue = "submenu";
        }
        else
        {
            action = Items[parentId].action;
            if (UpdatesSubmenuChildren.TryGetValue(action, out var children))
            {
                childrenIds = children.ToArray();
                childrenDisplayValue = "submenu";
            }
        }

        var rootDict = w.WriteDictionaryStart();
        w.WriteDictionaryEntryStart();
        w.WriteString("children-display");
        w.WriteVariantString(childrenDisplayValue);
        w.WriteDictionaryEnd(rootDict);

        var av = w.WriteArrayStart(DBusType.Variant);
        foreach (var id in childrenIds)
            if (Items.TryGetValue(id, out var item))
                w.WriteVariant(BuildMenuItemVariant(id, item.Label, item.Type, item.Enabled, item.icon, item.subMenu));
        w.WriteArrayEnd(av);

        context.Reply(w.CreateMessage());
        return ValueTask.CompletedTask;
    }

    private async ValueTask HandleEvent(MethodContext context)
    {
        var reader = context.Request.GetBodyReader();
        var id = reader.ReadInt32();
        var event_ = reader.ReadString();
        reader.ReadVariantValue();
        reader.ReadUInt32();

        if (event_ == "clicked")
        {
            var action = Items[id].action;
            switch (action)
            {
                case MenuEnum.CheckForUpdates:
                    var updates = await new UpdateService(this).CheckForUpdates();
                    new NotificationHandler().SendNotif(connection,
                        updates > 0 ? $"Updates available: {updates}" : $"No updates available.");

                    break;
                case MenuEnum.OpenShelly:
                    AppRunner.LaunchAppIfNotRunning("");

                    break;
                case MenuEnum.UpdatePackages:
                    _ = Task.Run(async () =>
                    {
                        await AppRunner.SpawnTerminalWithCommandAsync("sudo shelly -a");
                        await new UpdateService(this).CheckForUpdates();
                    });
                    break;
                case MenuEnum.Exit:
                    OnExitRequested?.Invoke();
                    break;
                case MenuEnum.None:
                case MenuEnum.AurUpdate:
                case MenuEnum.FlatpakUpdate:
                case MenuEnum.StandardUpdate:
                case MenuEnum.LastTime:
                default:
                    break;
            }
        }

        using var w = context.CreateReplyWriter("");
        context.Reply(w.CreateMessage());
    }

    private static ValueTask HandleEventGroup(MethodContext context)
    {
        using var w = context.CreateReplyWriter("ai");
        var arr = w.WriteArrayStart(DBusType.Int32);
        w.WriteArrayEnd(arr);
        context.Reply(w.CreateMessage());
        return ValueTask.CompletedTask;
    }

    private static ValueTask HandleGetGroupProperties(MethodContext context)
    {
        var reader = context.Request.GetBodyReader();
        var ids = new List<int>();
        var arrStart = reader.ReadArrayStart(DBusType.Int32);
        while (reader.HasNext(arrStart))
            ids.Add(reader.ReadInt32());

        using var w = context.CreateReplyWriter("a(ia{sv})");
        var arr = w.WriteArrayStart(DBusType.Struct);
        foreach (var id in ids)
        {
            w.WriteStructureStart();
            w.WriteInt32(id);
            var props = new Dictionary<string, VariantValue>();
            if (Items.TryGetValue(id, out var item))
            {
                props["label"] = item.Label;
                props["type"] = item.Type;
                props["enabled"] = true;
                props["visible"] = true;
                props["children-display"] = "submenu";
            }

            w.WriteDictionary(props);
            w.WriteArrayEnd(arr);
        }

        w.WriteArrayEnd(arr);

        context.Reply(w.CreateMessage());
        return ValueTask.CompletedTask;
    }

    private static ValueTask HandleGetProperty(MethodContext context)
    {
        var reader = context.Request.GetBodyReader();

        using var w = context.CreateReplyWriter("v");
        switch (reader.ReadString())
        {
            case "label" when Items.TryGetValue(reader.ReadInt32(), out var item):
                w.WriteVariantString(item.Label);
                break;
            case "enabled":
            case "visible":
                w.WriteVariantBool(true);
                break;
            case "children-display":
                w.WriteVariantString("submenu");
                break;
            default:
                w.WriteVariantString("");
                break;
        }

        context.Reply(w.CreateMessage());
        return ValueTask.CompletedTask;
    }

    private static uint _revision = 1;

    public void NotifyChildrenDisplayChanged(SyncModel syncModel)
    {
        var startValue = 101;

        try
        {
            //Remove the current index's so we can reinsert them if they exist now...
            var existingParents = Items.Where(kvp =>
                    kvp.Value.action is MenuEnum.FlatpakUpdate or MenuEnum.AurUpdate or MenuEnum.StandardUpdate)
                .Select(kvp => kvp.Key)
                .ToList();
            foreach (var key in existingParents)
                Items.Remove(key);

            UpdatesSubmenuChildren.Clear();

            var flatpakIds = RegisterSubmenuItems(syncModel.Flatpaks, i => $"{i.Name} {i.Version}",
                MenuEnum.FlatpakUpdate, ref startValue);
            RegisterSubmenu(flatpakIds, MenuEnum.FlatpakUpdate, SubmenuId + 1, "Flatpak");

            var aurIds = RegisterSubmenuItems(syncModel.Aur, i => $"{i.Name} {i.OldVersion} -> {i.Version}",
                MenuEnum.AurUpdate, ref startValue);
            RegisterSubmenu(aurIds, MenuEnum.AurUpdate, SubmenuId + 2, "AUR");

            var packageIds = RegisterSubmenuItems(syncModel.Packages, i => $"{i.Name} {i.OldVersion} -> {i.Version}",
                MenuEnum.StandardUpdate, ref startValue);
            RegisterSubmenu(packageIds, MenuEnum.StandardUpdate, SubmenuId + 3, "Standard");
        }
        catch (Exception e)
        {
            Console.WriteLine("Error updating DBus menu: " + e.Message);
        }

        var time = GetIndexByAction(MenuEnum.LastTime);
        Items[time!.Value] = ($"Last check: {DateTime.Now:HH:mm MM/dd}", "standard", false, "", "", MenuEnum.LastTime);

        _revision++;

        using var writer = connection.GetMessageWriter();

        writer.WriteSignalHeader(
            path: Path,
            @interface: "com.canonical.dbusmenu",
            member: "ItemsPropertiesUpdated",
            signature: "a(ia{sv})a(ias)");

        var updatedArr = writer.WriteArrayStart(DBusType.Struct);

        WriteSubmenuEntry(writer, GetIndexByAction(MenuEnum.StandardUpdate) ?? -1, "Standard");
        WriteSubmenuEntry(writer, GetIndexByAction(MenuEnum.AurUpdate) ?? -1, "Aur");
        WriteSubmenuEntry(writer, GetIndexByAction(MenuEnum.FlatpakUpdate) ?? -1, "Flatpak");

        writer.WriteStructureStart();
        writer.WriteInt32(time!.Value);
        writer.WriteDictionary(new Dictionary<string, VariantValue>
        {
            { "label", Items[time.Value].Label }
        });

        writer.WriteStructureStart();
        writer.WriteInt32(0);
        writer.WriteDictionary(new Dictionary<string, VariantValue>
        {
            { "children-display", "submenu" }
        });

        writer.WriteArrayEnd(updatedArr);

        var removedArr = writer.WriteArrayStart(DBusType.Struct);
        writer.WriteArrayEnd(removedArr);

        connection.TrySendMessage(writer.CreateMessage());

        using var layoutWriter = connection.GetMessageWriter();
        layoutWriter.WriteSignalHeader(
            path: Path,
            @interface: "com.canonical.dbusmenu",
            member: "LayoutUpdated",
            signature: "ui");

        layoutWriter.WriteUInt32(_revision);
        layoutWriter.WriteInt32(0);
        connection.TrySendMessage(layoutWriter.CreateMessage());
        Console.WriteLine($"[DBusMenu] Sent LayoutUpdated signal with revision {_revision}");
    }

    #region Sub Menu Helpers

    private static void WriteSubmenuEntry(MessageWriter writer, int id, string label)
    {
        writer.WriteStructureStart();
        writer.WriteInt32(id);
        writer.WriteDictionary(new Dictionary<string, VariantValue>
        {
            { "label", label },
            { "type", "standard" },
            { "enabled", true },
            { "children-display", "submenu" }
        });
    }

    private VariantValue[] GetSubmenuChildren(MenuEnum menuEnum)
    {
        return UpdatesSubmenuChildren[menuEnum]
            .Select(childId => Items.TryGetValue(childId, out var childItem)
                ? BuildMenuItemVariant(childId, childItem.Label, childItem.Type, childItem.Enabled, childItem.icon,
                    childItem.subMenu)
                : VariantValue.Struct(VariantValue.Int32(childId),
                    new Dict<string, VariantValue>(new Dictionary<string, VariantValue>()),
                    VariantValue.ArrayOfVariant(Array.Empty<VariantValue>())))
            .ToArray();
    }

    private static List<int> RegisterSubmenuItems<T>(
        IEnumerable<T> source,
        Func<T, string> labelSelector,
        MenuEnum menuEnum,
        ref int startValue)
    {
        var ids = new List<int>();
        foreach (var item in source)
        {
            Items.Remove(startValue);
            Items.Add(startValue, (labelSelector(item), "standard", true, "", "", action: menuEnum));
            ids.Add(startValue);
            startValue++;
        }

        return ids;
    }

    private static void RegisterSubmenu(List<int> ids, MenuEnum menuEnum, int parentId, string parentLabel)
    {
        if (ids.Count <= 0) return;
        UpdatesSubmenuChildren.Add(menuEnum, ids);
        Items.Add(parentId, (parentLabel, "standard", true, "", "submenu", menuEnum));
    }

    private static int? GetIndexByAction(MenuEnum action)
    {
        var match = Items.FirstOrDefault(kvp => kvp.Value.action == action);
        return match.Value != default ? match.Key : null;
    }

    #endregion
}