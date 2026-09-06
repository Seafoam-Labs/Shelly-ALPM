const config = @import("config.zig");
const downgrade = @import("downgrade.zig");
const backup = @import("backup.zig");
const builder = @import("builder.zig");
const install = @import("install.zig");
const keyring = @import("keyring.zig");
const list = @import("list.zig");
const list_updates = @import("list_updates.zig");
const mark = @import("mark.zig");
const news = @import("news.zig");
const purify = @import("purify.zig");
const remove = @import("remove.zig");
const run = @import("run.zig");
const search = @import("search.zig");
const search_install = @import("search_install.zig");
const sync = @import("sync.zig");
const update = @import("update.zig");
const upgrade = @import("upgrade.zig");
const utility = @import("utility.zig");
const resolve = @import("resolve.zig");
const parser = @import("../cli/parser.zig");
const runtime = @import("../runtime/context.zig");

pub fn dispatch(
    _: ?*anyopaque,
    context: *runtime.RuntimeContext,
    invocation: *const parser.Invocation,
) !u8 {
    if (try search_install.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try upgrade.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try sync.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try update.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try downgrade.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try backup.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try install.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try keyring.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try list.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try list_updates.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try mark.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try news.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try search.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try config.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try purify.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try remove.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try run.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try utility.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try builder.dispatch(context, invocation)) |exit_code| return exit_code;
    if (try resolve.dispatch(context, invocation)) |exit_code| return exit_code;
    return runtime.unimplemented(null, context, invocation);
}
