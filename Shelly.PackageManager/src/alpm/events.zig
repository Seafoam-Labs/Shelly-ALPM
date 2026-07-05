const std = @import("std");
const bindings = @import("bindings.zig");
const c = bindings.libalpm;

// --- Public event argument types ---

pub const ProgressArgs = struct {
    progress_type: c_int,
    pkg_name: ?[]const u8,
    percent: c_int,
    howmany: c_ulong,
    current: c_ulong,
};

pub const QuestionArgs = struct {
    question: ?[]const u8,
    question_type: c_int,
    options: []const []const u8,
    response: ?c_int = null,

    // For SelectProvider questions
    provider_options: ?[]ProviderOption = null,
    dependency_name: ?[]const u8 = null,
};

pub const ProviderOption = struct {
    name: []const u8,
    description: []const u8,
    is_installed: bool,
};

pub const ErrorArgs = struct {
    message: []const u8,
};

pub const InformationalArgs = struct {
    event_type: c_int,
    message: []const u8,
};

pub const ScriptletArgs = struct {
    line: []const u8,
};

pub const HookArgs = struct {
    description: ?[]const u8,
    position: c_ulong,
    total: c_ulong,
};

pub const PacnewArgs = struct {
    file: ?[]const u8,
};

pub const PacsaveArgs = struct {
    pkg_name: ?[]const u8,
    file: ?[]const u8,
};

pub const ReplacesArgs = struct {
    pkg_name: []const u8,
    repository: []const u8,
    replaces: []const []const u8,
};

// --- Generic handler (replaces C# EventHandler<T>) ---

pub fn Handler(comptime Args: type) type {
    return struct {
        pub const Fn = *const fn (data: ?*anyopaque, args: Args) void;

        pub const T = struct {
            function: Fn,
            data: ?*anyopaque = null,

            pub fn call(self: T, args: Args) void {
                self.function(self.data, args);
            }
        };
    };
}

// --- Question response (blocking pattern) ---

pub const QuestionResponse = struct {
    answer: ?c_int = null,
    pkg: ?[]const u8 = null,
    choice: ?c_int = null,
};

// --- Event dispatcher ---
// This is the equivalent of C# `Progress?.Invoke(...)` but generic.

pub const Dispatcher = struct {
    // Progress events
    progress: std.ArrayList(Handler(ProgressArgs).T) = .empty,

    // Question events — raised, then we block on the channel
    question: std.ArrayList(Handler(QuestionArgs).T) = .empty,
    question_response: QuestionResponse = .{},

    // Error events
    errorEvents: std.ArrayList(Handler(ErrorArgs).T) = .empty,

    // Informational events
    informational: std.ArrayList(Handler(InformationalArgs).T) = .empty,

    // Scriptlet events
    scriptlet: std.ArrayList(Handler(ScriptletArgs).T) = .empty,

    // Hook events
    hook: std.ArrayList(Handler(HookArgs).T) = .empty,

    // Pacnew / Pacsave events
    pacnew: std.ArrayList(Handler(PacnewArgs).T) = .empty,
    pacsave: std.ArrayList(Handler(PacsaveArgs).T) = .empty,

    // Replaces events
    replaces: std.ArrayList(Handler(ReplacesArgs).T) = .empty,

    // Allocator — owned by the Manager, passed in
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.progress.deinit();
        self.question.deinit();
        self.errorEvents.deinit();
        self.informational.deinit();
        self.scriptlet.deinit();
        self.hook.deinit();
        self.pacnew.deinit();
        self.pacsave.deinit();
        self.replaces.deinit();
    }

    // --- Subscriber registration ---

    pub fn addProgressHandler(self: *Dispatcher, handler: Handler(ProgressArgs).T) void {
        self.progress.append(handler) catch {};
    }

    pub fn addQuestionHandler(self: *Dispatcher, handler: Handler(QuestionArgs).T) void {
        self.question.append(handler) catch {};
    }

    pub fn addErrorHandler(self: *Dispatcher, handler: Handler(ErrorArgs).T) void {
        self.errorEvents.append(handler) catch {};
    }

    pub fn addInformationalHandler(self: *Dispatcher, handler: Handler(InformationalArgs).T) void {
        self.informational.append(handler) catch {};
    }

    pub fn addScriptletHandler(self: *Dispatcher, handler: Handler(ScriptletArgs).T) void {
        self.scriptlet.append(handler) catch {};
    }

    pub fn addHookHandler(self: *Dispatcher, handler: Handler(HookArgs).T) void {
        self.hook.append(handler) catch {};
    }

    pub fn addPacnewHandler(self: *Dispatcher, handler: Handler(PacnewArgs).T) void {
        self.pacnew.append(handler) catch {};
    }

    pub fn addPacsaveHandler(self: *Dispatcher, handler: Handler(PacsaveArgs).T) void {
        self.pacsave.append(handler) catch {};
    }

    pub fn addReplacesHandler(self: *Dispatcher, handler: Handler(ReplacesArgs).T) void {
        self.replaces.append(handler) catch {};
    }

    // --- Event raising (replaces C# `event?.Invoke(...)`) ---

    pub fn raiseProgress(self: *Dispatcher, args: ProgressArgs) void {
        for (self.progress.items) |h| h.call(args);
    }

    pub fn raiseQuestion(self: *Dispatcher, args: QuestionArgs) void {
        for (self.question.items) |h| h.call(args);
    }

    pub fn raiseError(self: *Dispatcher, args: ErrorArgs) void {
        for (self.errorEvents.items) |h| h.call(args);
    }

    pub fn raiseInformational(self: *Dispatcher, args: InformationalArgs) void {
        for (self.informational.items) |h| h.call(args);
    }

    pub fn raiseScriptlet(self: *Dispatcher, args: ScriptletArgs) void {
        for (self.scriptlet.items) |h| h.call(args);
    }

    pub fn raiseHook(self: *Dispatcher, args: HookArgs) void {
        for (self.hook.items) |h| h.call(args);
    }

    pub fn raisePacnew(self: *Dispatcher, args: PacnewArgs) void {
        for (self.pacnew.items) |h| h.call(args);
    }

    pub fn raisePacsave(self: *Dispatcher, args: PacsaveArgs) void {
        for (self.pacsave.items) |h| h.call(args);
    }

    pub fn raiseReplaces(self: *Dispatcher, args: ReplacesArgs) void {
        for (self.replaces.items) |h| h.call(args);
    }
};
