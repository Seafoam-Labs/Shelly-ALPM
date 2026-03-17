using System.Net.Http.Headers;
using Shelly_Notifications.Enums;
using Shelly_Notifications.Models;
using Shelly_Notifications.Services;
using Tmds.DBus.Protocol;

namespace Shelly_Notifications.DbusHandlers;

public class DBusMenuHandler(Connection connection) : IPathMethodHandler
{
    public string Path => "/MenuBar";
    public bool HandlesChildPaths => false;

    private DateTime lastUpdateCheck = DateTime.Now;

    public event Action? OnExitRequested;

    private static readonly
        Dictionary<int, (string Label, string Type, bool Enabled, string icon, string subMenu, MenuEnum action)> Items =
            new()
            {
                [1] = ("Open Shelly", "standard", true, "shelly", "", MenuEnum.OpenShelly),
                [2] = ("Update Packages", "standard", true, "", "", MenuEnum.UpdatePackages),
                [3] = ("Check for Updates", "standard", true, "", "", MenuEnum.CheckForUpdates),
                [5] = ("", "separator", false, "", "", MenuEnum.None),
                [6] = ("Exit", "standard", true, "", "", action: MenuEnum.Exit),
            };

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

        VariantValue[] children;
        if (id == GetIndexByAction(MenuEnum.StandardUpdate) && childrenDisplay == "submenu")
        {
            children = UpdatesSubmenuChildren[MenuEnum.StandardUpdate]
                .Select(childId => Items.TryGetValue(childId, out var childItem)
                    ? BuildMenuItemVariant(childId, childItem.Label, childItem.Type, childItem.Enabled, childItem.icon,
                        childItem.subMenu)
                    : VariantValue.Struct(VariantValue.Int32(childId),
                        new Dict<string, VariantValue>(new Dictionary<string, VariantValue>()),
                        VariantValue.ArrayOfVariant(Array.Empty<VariantValue>())))
                .ToArray();
        }
        else if(id == GetIndexByAction(MenuEnum.AurUpdate) && childrenDisplay == "submenu")
        {
            children = UpdatesSubmenuChildren[MenuEnum.AurUpdate]
                .Select(childId => Items.TryGetValue(childId, out var childItem)
                    ? BuildMenuItemVariant(childId, childItem.Label, childItem.Type, childItem.Enabled, childItem.icon,
                        childItem.subMenu)
                    : VariantValue.Struct(VariantValue.Int32(childId),
                        new Dict<string, VariantValue>(new Dictionary<string, VariantValue>()),
                        VariantValue.ArrayOfVariant(Array.Empty<VariantValue>())))
                .ToArray();
        }
        else if(id == GetIndexByAction(MenuEnum.FlatpakUpdate) && childrenDisplay == "submenu")
        {
            children = UpdatesSubmenuChildren[MenuEnum.FlatpakUpdate]
                .Select(childId => Items.TryGetValue(childId, out var childItem)
                    ? BuildMenuItemVariant(childId, childItem.Label, childItem.Type, childItem.Enabled, childItem.icon,
                        childItem.subMenu)
                    : VariantValue.Struct(VariantValue.Int32(childId),
                        new Dict<string, VariantValue>(new Dictionary<string, VariantValue>()),
                        VariantValue.ArrayOfVariant(Array.Empty<VariantValue>())))
                .ToArray();
        }
        else
        {
            children = Array.Empty<VariantValue>();
        }

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

        int[] childrenIds;
        string childrenDisplayValue;

        if (parentId == 0)
        {
            childrenIds = Items.Keys.Where(k => k < 100).ToArray();
            childrenDisplayValue = "submenu";
        }
        else if (parentId == 9)
        {
            if (UpdatesSubmenuChildren.ContainsKey(MenuEnum.FlatpakUpdate))
                childrenIds = UpdatesSubmenuChildren[MenuEnum.FlatpakUpdate].ToArray();
            else
                childrenIds = Array.Empty<int>();
            childrenDisplayValue = "submenu";
        }
        else if (parentId == 8) // AUR
        {
            if (UpdatesSubmenuChildren.ContainsKey(MenuEnum.AurUpdate))
                childrenIds = UpdatesSubmenuChildren[MenuEnum.AurUpdate].ToArray();
            else
                childrenIds = Array.Empty<int>();
            childrenDisplayValue = "submenu";
        }
        else if (parentId == 7)
        {
            if (UpdatesSubmenuChildren.ContainsKey(MenuEnum.StandardUpdate))
                childrenIds = UpdatesSubmenuChildren[MenuEnum.StandardUpdate].ToArray();
            else
                childrenIds = Array.Empty<int>();
            childrenDisplayValue = "submenu";
        }
        else
        {
            childrenIds = Array.Empty<int>();
            childrenDisplayValue = "";
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
                    new NotificationHandler().SendNotif(connection,
                        $"Updates available: {await new UpdateService().CheckForUpdates()}");
                    break;
                case MenuEnum.OpenShelly:
                    AppRunner.LaunchAppIfNotRunning("");
                    break;
                case MenuEnum.UpdatePackages:
                    AppRunner.LaunchAppIfNotRunning("--page UpdatePackage");
                    break;
                case MenuEnum.Exit:
                    OnExitRequested?.Invoke();
                    break;
                case MenuEnum.None:
                case MenuEnum.AurUpdate:
                case MenuEnum.FlatpakUpdate:
                case MenuEnum.StandardUpdate:
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

    public void NotifyChildrenDisplayChanged(SyncModel syncModel)
    {
        var startValue = 101;
        syncModel.Aur = [];
        syncModel.Flatpaks = [];
        
        syncModel.Aur.Add(new SyncAurModel
        {
            Name = "test",
            Version = "v0.1"
        });
        
        syncModel.Flatpaks.Add(new SyncFlatpakModel()
        {
            Name = "test",
            Version = "v0.2"
        });
        
        try
        {
            UpdatesSubmenuChildren.Clear();

            // Flatpak updates
            var flatpakIds = new List<int>();
            foreach (var item in syncModel.Flatpaks)
            {
                Items.Remove(startValue);
                Items.Add(startValue,
                    (item.Name + " new version: " + item.Version, "standard", true, "", "",
                        action: MenuEnum.FlatpakUpdate)!);
                flatpakIds.Add(startValue);
                startValue++;
            }

            if (flatpakIds.Count > 0)
            {
                UpdatesSubmenuChildren.Add(MenuEnum.FlatpakUpdate, flatpakIds);
                Items.Add(9, ("Flatpak", "standard", true, "", "submenu", MenuEnum.FlatpakUpdate));
            }
                

            // AUR updates
            var aurIds = new List<int>();
            foreach (var item in syncModel.Aur)
            {
                Items.Remove(startValue);
                Items.Add(startValue,
                    (item.Name + " new version: " + item.Version, "standard", true, "", "", action: MenuEnum.AurUpdate));
                aurIds.Add(startValue);
                startValue++;
            }

            if (aurIds.Count > 0)
            {
                UpdatesSubmenuChildren.Add(MenuEnum.AurUpdate, aurIds);
                Items.Add(8, ("AUR", "standard", true, "", "submenu", MenuEnum.AurUpdate));
            }
              

            // Standard package updates
            var packageIds = new List<int>();
            foreach (var item in syncModel.Packages)
            {
                Items.Remove(startValue);
                Items.Add(startValue,
                    (item.Name + " new version: " + item.Version, "standard", true, "", "",
                        action: MenuEnum.StandardUpdate));
                packageIds.Add(startValue);
                startValue++;
            }
            if (packageIds.Count > 0)
            {
                UpdatesSubmenuChildren.Add(MenuEnum.StandardUpdate, packageIds);
                Items.Add(7, ("Standard", "standard", true, "", "submenu", MenuEnum.StandardUpdate));
            }
        }
        catch (Exception e)
        {
            Console.WriteLine("Error updating DBus menu: " + e.Message);
        }

        using var writer = connection.GetMessageWriter();

        writer.WriteSignalHeader(
            path: Path,
            @interface: "com.canonical.dbusmenu",
            member: "ItemsPropertiesUpdated",
            signature: "a(ia{sv})a(ias)");

        var updatedArr = writer.WriteArrayStart(DBusType.Struct);
        writer.WriteStructureStart();
        writer.WriteInt32(7);
        writer.WriteDictionary(new Dictionary<string, VariantValue>
        {
            { "label", "Standard" },
            { "type", "standard" },
            { "enabled", true },
            { "children-display", "submenu" }
        });
        writer.WriteStructureStart();
        writer.WriteInt32(8);
        writer.WriteDictionary(new Dictionary<string, VariantValue>
        {
            { "label", "Aur" },
            { "type", "standard" },
            { "enabled", true },
            { "children-display", "submenu" }
        });
        writer.WriteStructureStart();
        writer.WriteInt32(9);
        writer.WriteDictionary(new Dictionary<string, VariantValue>
        {
            { "label", "Flatpak" },
            { "type", "standard" },
            { "enabled", true },
            { "children-display", "submenu" }
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

        // Send LayoutUpdated signal for root menu
        using var layoutWriter = connection.GetMessageWriter();
        layoutWriter.WriteSignalHeader(
            path: Path,
            @interface: "com.canonical.dbusmenu",
            member: "LayoutUpdated",
            signature: "ui");
        layoutWriter.WriteUInt32(1);
        layoutWriter.WriteInt32(0);
        connection.TrySendMessage(layoutWriter.CreateMessage());
    }

    private static int? GetIndexByAction(MenuEnum action)
    {
        var match = Items.FirstOrDefault(kvp => kvp.Value.action == action);
        return match.Value != default ? match.Key : null;
    }
}