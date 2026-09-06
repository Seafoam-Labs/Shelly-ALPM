//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const flatpak_backend_loader = @import("flatpak/backend_loader.zig");

pub const alpm = struct {
    pub const manager = @import("alpm/manager.zig");
    pub const bootstrap = @import("alpm/bootstrap.zig");
    pub const bindings = @import("alpm/bindings.zig");
    pub const events = @import("alpm/events.zig");
    pub const configuration = @import("alpm/configuration.zig");
    pub const cache_manager = @import("alpm/cache_manager.zig");
    pub const archive_manager = @import("alpm/archive_manager.zig");
    pub const pacfile_manager = @import("alpm/pacfile_manager.zig");

    pub const InitOptions = manager.InitOptions;
    pub const Manager = manager.Manager;
    pub const BootstrapOptions = bootstrap.Options;
    pub const BootstrapResult = bootstrap.Result;
    pub const TransFlag = bindings.libalpm.TransFlag;
    pub const SigLevel = bindings.libalpm.SigLevel;
    pub const OwnedPackage = bindings.libalpm.OwnedPackage;
    pub const OwnedPackageWithUpdate = bindings.libalpm.OwnedPackageWithUpdate;
    pub const ReverseDependencyOptions = manager.ReverseDependencyOptions;
    pub const DependencySatisfier = manager.DependencySatisfier;
    pub const RestartReport = manager.RestartReport;
    pub const AffectedProcess = manager.AffectedProcess;
    pub const ServiceRestartFailure = manager.ServiceRestartFailure;
    pub const ServiceRestartFailureKind = manager.ServiceRestartFailureKind;
    pub const Repository = configuration.Configuration.Repository;
    pub const compare_package_versions = manager.Manager.compare_package_versions;
    pub const version_compare = manager.Manager.version_compare;
    pub const ArchiveManager = archive_manager.ArchiveManager;
    pub const ArchiveManagerOptions = archive_manager.Options;
    pub const ArchiveError = archive_manager.Error;
    pub const ArchiveDiscoveryError = archive_manager.DiscoveryError;
    pub const ArchiveInstallError = archive_manager.InstallError;
    pub const ArchiveSource = archive_manager.Source;
    pub const ArchiveEndpoint = archive_manager.ArchiveEndpoint;
    pub const DowngradeCandidate = archive_manager.DowngradeCandidate;
    pub const PreparedDowngradePackage = archive_manager.PreparedPackage;
    pub const parse_archive_listing = archive_manager.parseArchiveListing;
    pub const CacheManager = cache_manager.CacheManager;
    pub const CacheManagerOptions = cache_manager.Options;
    pub const CacheCleanOptions = cache_manager.CleanOptions;
    pub const CacheInstalledFilter = cache_manager.InstalledFilter;
    pub const CacheEntry = cache_manager.Entry;
    pub const CacheRemovalItem = cache_manager.RemovalItem;
    pub const CacheRemovalPlan = cache_manager.RemovalPlan;
    pub const CacheExecutionResult = cache_manager.ExecutionResult;
    pub const CacheError = cache_manager.Error;
    pub const parse_cache_package_filename = cache_manager.parsePackageFilename;
    pub const PacfileManager = pacfile_manager.PacfileManager;
    pub const PacfileManagerOptions = pacfile_manager.Options;
    pub const PacfileError = pacfile_manager.Error;
    pub const PacfileSearchMode = pacfile_manager.SearchMode;
    pub const PacfileKind = pacfile_manager.Kind;
    pub const PacfileState = pacfile_manager.State;
    pub const PacfileDiffMode = pacfile_manager.DiffMode;
    pub const ParsedPacfilePath = pacfile_manager.ParsedPath;
    pub const Pacfile = pacfile_manager.Pacfile;
    pub const PacfileToolResult = pacfile_manager.ToolResult;
    pub const PacfileViewResult = pacfile_manager.ViewResult;
    pub const PreparedPacfileMerge = pacfile_manager.PreparedMerge;
    pub const parse_pacfile_path = pacfile_manager.parsePacfilePath;
};

pub const user_errors = @import("shared/user_errors.zig");

pub const aur = @import("aur/manager.zig");

pub const builder = @import("aur/builder/builder.zig");
pub const process_runner = @import("aur/builder.zig");
pub const source_pgp_verifier = @import("shared/source_pgp_verifier.zig");
pub const source_pgp_keyring = @import("shared/source_pgp_keyring.zig");
pub const package_signer = @import("shared/package_signer.zig");

pub const flatpak = struct {
    pub const manager = @import("flatpak/manager.zig");
    pub const remote_manager = @import("flatpak/remote_manager.zig");
    pub const appstream_manager = @import("flatpak/appstream_manager.zig");
    pub const appstream_parser = @import("flatpak/appstream_parser.zig");
    pub const events = @import("flatpak/events.zig");
    pub const types = @import("flatpak/types.zig");
    pub const errors = @import("flatpak/errors.zig");
    pub const eol = @import("flatpak/eol.zig");

    pub const Manager = manager.Manager;
    pub const Scope = types.Scope;
    pub const RefKind = types.RefKind;
    pub const InstalledApplication = types.InstalledApplication;
    pub const InstalledRef = types.InstalledRef;
    pub const Ref = types.Ref;
    pub const Remote = types.Remote;
    pub const RemoteRef = types.RemoteRef;
    pub const RunningInstance = types.RunningInstance;
    pub const UnusedDependency = types.UnusedDependency;
    pub const EolStatus = types.EolStatus;
    pub const EolRebase = manager.EolRebase;
    pub const EolDetection = manager.EolDetection;
    pub const RemoteManager = remote_manager.RemoteManager;
    pub const AppstreamManager = appstream_manager.AppstreamManager;
    pub const AppstreamCatalog = types.AppstreamCatalog;
    pub const AppstreamError = appstream_manager.Error;
    pub const AppstreamParser = appstream_parser.AppstreamParser;
    pub const AppstreamIcon = types.AppstreamIcon;
    pub const AppstreamImage = types.AppstreamImage;
    pub const AppstreamScreenshot = types.AppstreamScreenshot;
    pub const AppstreamRelease = types.AppstreamRelease;
    pub const AppstreamApp = types.AppstreamApp;
    pub const BackendInfo = flatpak_backend_loader.BackendInfo;
    pub const BackendStatus = flatpak_backend_loader.BackendStatus;
    pub const backendStatus = flatpak_backend_loader.backendStatus;
    pub const FlatpakEventDispatcher = events.Dispatcher;
    pub const FlatpakEventType = events.EventType;
    pub const FlatpakStatusArgs = events.StatusArgs;
    pub const FlatpakProgressArgs = events.ProgressArgs;
    pub const FlatpakStatusHandler = events.StatusHandler;
    pub const FlatpakProgressHandler = events.ProgressHandler;
    pub const FlatpakCancellation = events.Cancellation;
};

pub const appimage = struct {
    pub const environment = @import("appimage/environment.zig");
    pub const manager = @import("appimage/manager.zig");
    pub const update_manager = @import("appimage/update_manager.zig");
    pub const bindings = @import("appimage/bindings.zig");
    pub const events = @import("appimage/events.zig");

    pub const Manager = manager.AppImageManager;
    pub const UpdateManager = update_manager.UpdateManager;
    pub const AppImage = bindings.appimage.AppImage;
    pub const AppImageUpdate = bindings.appimage.AppImageUpdate;
    pub const UpdateType = bindings.appimage.UpdateType;
    pub const UpdateList = bindings.appimage.UpdateList;
    pub const EventDispatcher = events.Dispatcher;
    pub const StatusKind = events.StatusKind;
    pub const StatusArgs = events.StatusArgs;
    pub const DownloadProgressArgs = events.DownloadProgressArgs;
    pub const StatusHandler = events.StatusHandler;
    pub const DownloadProgressHandler = events.DownloadProgressHandler;
};

pub const pkgbuild = struct {
    pub const parser = @import("pkgbuild/pkgbuild_parser.zig");
    pub const validation = @import("pkgbuild/shared_validtor.zig");
    pub const homograph_validator = @import("pkgbuild/homograph_validator.zig");
    pub const post_install_validator = @import("pkgbuild/post_install_validator.zig");
    pub const install_script = @import("pkgbuild/install_script.zig");
    pub const install_script_scanner = @import("pkgbuild/install_script_scanner.zig");

    pub const Parser = parser.PkgbuildParser;
    pub const HomographValidator = homograph_validator.HomographValidator;
    pub const PostInstallValidator = post_install_validator.PostInstallValidator;
    pub const InstallScript = install_script.Script;
    pub const InstallScriptScanner = install_script_scanner.InstallScriptScanner;
};

pub const local = struct {
    pub const manager = @import("local/manager.zig");
    pub const file_inspector = @import("local/file_inspector.zig");
    pub const xdg_integration = @import("local/xdg_integration.zig");
    pub const events = @import("local/events.zig");

    pub const Manager = manager.Manager;
    pub const Options = manager.Options;
    pub const Error = manager.Error;
    pub const Package = manager.Package;
    pub const Inspector = file_inspector.Inspector;
    pub const XdgIntegration = xdg_integration.Integration;
    pub const MessageLevel = events.Level;
};

/// Backend-neutral lifecycle, event, question, and cancellation API.
pub const operation = @import("operation_context");

/// Zig 0.16 HTTP client with a compact, VPN-compatible TLS ClientHello.
pub const HttpClient = @import("ShellyHttp");

pub const shared = struct {
    pub const archive = @import("archive");
    pub const downloader = @import("shared/downloader.zig");
    pub const list_dictionary = @import("shared/list_dictionary.zig");
    pub const xdg_paths = @import("shared/xdg_paths.zig");
    pub const operation_context = operation;

    pub const Downloader = downloader.CoreDownloader;
    pub const OperationContext = operation.OperationContext;
    pub const Operation = operation.Operation;
};

pub const AlpmManagerInitOptions = alpm.InitOptions;
pub const AlpmManager = alpm.Manager;
pub const CacheManager = alpm.CacheManager;
pub const PacfileManager = alpm.PacfileManager;
pub const AlpmArchiveManager = alpm.ArchiveManager;
pub const AurManager = aur.Manager;
pub const FlatpakManager = flatpak.Manager;
pub const AppImageManager = appimage.Manager;
pub const LocalManager = local.Manager;
pub const OperationContext = operation.OperationContext;
pub const Operation = operation.Operation;
pub const OperationEvent = operation.Event;
pub const OperationBackend = operation.Backend;
pub const OperationKind = operation.OperationKind;
pub const OperationStatusLevel = operation.StatusLevel;
pub const OperationCompletionStatus = operation.CompletionStatus;
pub const OperationQuestion = operation.Question;
pub const OperationPurpose = operation.QuestionPurpose;
pub const OperationQuestionRequest = operation.QuestionRequest;
pub const OperationQuestionResponse = operation.QuestionResponse;
pub const OperationQuestionKind = operation.QuestionKind;
pub const OperationQuestionOption = operation.QuestionOption;
pub const OperationQuestionAttachment = operation.QuestionAttachment;
pub const OperationReviewSeverity = operation.ReviewSeverity;
pub const OperationReviewFinding = operation.ReviewFinding;
pub const OperationReviewPayload = operation.ReviewPayload;
pub const OperationPgpKeyImportPayload = operation.PgpKeyImportPayload;
pub const OperationTransactionAction = operation.TransactionAction;
pub const OperationTransactionPackageSource = operation.TransactionPackageSource;
pub const OperationTransactionPackageRole = operation.TransactionPackageRole;
pub const OperationTransactionPackage = operation.TransactionPackage;
pub const OperationTransactionPlan = operation.TransactionPlan;
pub const OperationEventHandler = operation.EventHandler;
pub const OperationQuestionHandler = operation.QuestionHandler;
pub const OperationCancellationHandler = operation.CancellationHandler;

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test "public AUR module exposes the package manager" {
    _ = aur.Manager;
    _ = aur.models.Package;
}

test "public library surface exposes package manager APIs" {
    _ = AlpmManager;
    _ = CacheManager;
    _ = PacfileManager;
    _ = AlpmArchiveManager;
    _ = AurManager;
    _ = FlatpakManager;
    _ = AppImageManager;
    _ = LocalManager;
    _ = alpm.TransFlag;
    _ = alpm.SigLevel;
    _ = alpm.DependencySatisfier;
    _ = alpm.RestartReport;
    _ = alpm.AffectedProcess;
    _ = alpm.ServiceRestartFailure;
    _ = alpm.ServiceRestartFailureKind;
    _ = alpm.Repository;
    _ = alpm.compare_package_versions;
    _ = alpm.version_compare;
    _ = alpm.ArchiveManagerOptions;
    _ = alpm.ArchiveError;
    _ = alpm.ArchiveDiscoveryError;
    _ = alpm.ArchiveInstallError;
    _ = alpm.ArchiveSource;
    _ = alpm.ArchiveEndpoint;
    _ = alpm.DowngradeCandidate;
    _ = alpm.PreparedDowngradePackage;
    _ = alpm.parse_archive_listing;
    _ = alpm.events.Dispatcher;
    _ = alpm.configuration.Configuration;
    _ = alpm.CacheCleanOptions;
    _ = alpm.CacheManagerOptions;
    _ = alpm.CacheInstalledFilter;
    _ = alpm.CacheEntry;
    _ = alpm.CacheRemovalItem;
    _ = alpm.CacheRemovalPlan;
    _ = alpm.CacheExecutionResult;
    _ = alpm.CacheError;
    _ = alpm.parse_cache_package_filename;
    _ = alpm.PacfileManagerOptions;
    _ = alpm.PacfileError;
    _ = alpm.PacfileSearchMode;
    _ = alpm.PacfileKind;
    _ = alpm.PacfileState;
    _ = alpm.PacfileDiffMode;
    _ = alpm.ParsedPacfilePath;
    _ = alpm.Pacfile;
    _ = alpm.PacfileToolResult;
    _ = alpm.PacfileViewResult;
    _ = alpm.PreparedPacfileMerge;
    _ = alpm.parse_pacfile_path;
    _ = flatpak.RemoteManager;
    _ = flatpak.AppstreamManager;
    _ = flatpak.InstalledApplication;
    _ = flatpak.AppstreamCatalog;
    _ = flatpak.AppstreamParser;
    _ = flatpak.AppstreamApp;
    _ = flatpak.FlatpakEventDispatcher;
    _ = flatpak.FlatpakStatusHandler;
    _ = flatpak.FlatpakProgressHandler;
    _ = flatpak.FlatpakCancellation;
    _ = flatpak.EolRebase;
    _ = flatpak.EolDetection;
    _ = flatpak.eol;
    _ = FlatpakManager.rebase_flatpak;
    _ = FlatpakManager.list_eol_flatpak;
    _ = FlatpakManager.detect_eol_flatpak;
    _ = appimage.UpdateManager;
    _ = appimage.AppImage;
    _ = appimage.AppImageUpdate;
    _ = appimage.UpdateType;
    _ = appimage.UpdateList;
    _ = appimage.EventDispatcher;
    _ = appimage.StatusHandler;
    _ = appimage.DownloadProgressHandler;
    _ = pkgbuild.Parser;
    _ = pkgbuild.HomographValidator;
    _ = pkgbuild.PostInstallValidator;
    _ = local.Package;
    _ = local.Options;
    _ = local.Error;
    _ = local.Inspector;
    _ = local.XdgIntegration;
    _ = local.MessageLevel;
    _ = local.events.Dispatcher;
    _ = shared.Downloader;
    _ = OperationContext;
    _ = Operation;
    _ = OperationEvent;
    _ = OperationBackend;
    _ = OperationKind;
    _ = OperationStatusLevel;
    _ = OperationCompletionStatus;
    _ = OperationQuestion;
    _ = OperationQuestionRequest;
    _ = OperationQuestionResponse;
    _ = OperationQuestionKind;
    _ = OperationQuestionOption;
    _ = OperationQuestionAttachment;
    _ = OperationEventHandler;
    _ = OperationQuestionHandler;
    _ = OperationCancellationHandler;
}

test "backend dispatchers share one operation event stream" {
    const Capture = struct {
        seen: [6]bool = .{false} ** 6,
        failures: usize = 0,

        fn receive(data: ?*anyopaque, event: operation.Event) void {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            switch (event) {
                .failure => |failure| {
                    self.seen[@intFromEnum(failure.envelope.backend)] = true;
                    self.failures += 1;
                },
                else => {},
            }
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = operation.OperationContext.init(std.testing.allocator, threaded.io());
    defer context.deinit();
    var capture: Capture = .{};
    _ = try context.subscribe(.{ .function = Capture.receive, .data = &capture });

    var alpm_operation = context.begin(.{ .backend = .alpm, .kind = .install });
    var alpm_dispatcher = alpm.events.Dispatcher.init(std.testing.allocator);
    defer alpm_dispatcher.deinit();
    alpm_dispatcher.setOperation(&alpm_operation);
    alpm_dispatcher.raiseError(.{ .message = "alpm failure" });
    alpm_dispatcher.setOperation(null);
    alpm_operation.finish(.failed);

    var aur_operation = context.begin(.{ .backend = .aur, .kind = .build });
    var aur_dispatcher = aur.events.Dispatcher.init(std.testing.allocator);
    defer aur_dispatcher.deinit();
    aur_dispatcher.setOperation(&aur_operation);
    aur_dispatcher.raiseError(.{ .message = "aur failure" });
    aur_dispatcher.setOperation(null);
    aur_operation.finish(.failed);

    var flatpak_operation = context.begin(.{ .backend = .flatpak, .kind = .update });
    var flatpak_dispatcher = flatpak.events.Dispatcher.init(std.testing.allocator);
    defer flatpak_dispatcher.deinit();
    flatpak_dispatcher.setOperation(&flatpak_operation);
    flatpak_dispatcher.raiseStatus(.{ .event_type = .err, .message = "flatpak failure" });
    flatpak_dispatcher.setOperation(null);
    flatpak_operation.finish(.failed);

    var appimage_operation = context.begin(.{ .backend = .appimage, .kind = .update });
    var appimage_dispatcher = appimage.events.Dispatcher.init(std.testing.allocator);
    defer appimage_dispatcher.deinit();
    appimage_dispatcher.setOperation(&appimage_operation);
    appimage_dispatcher.raiseStatus(.{ .kind = .err, .message = "appimage failure" });
    appimage_dispatcher.setOperation(null);
    appimage_operation.finish(.failed);

    var local_operation = context.begin(.{ .backend = .local_package, .kind = .inspect });
    var local_dispatcher = local.events.Dispatcher.init(std.testing.allocator);
    defer local_dispatcher.deinit();
    local_dispatcher.setOperation(&local_operation);
    local_dispatcher.raise(.{ .level = .err, .text = "local failure" });
    local_dispatcher.setOperation(null);
    local_operation.finish(.failed);

    try std.testing.expectEqual(@as(usize, 5), capture.failures);
    try std.testing.expect(capture.seen[@intFromEnum(operation.Backend.alpm)]);
    try std.testing.expect(capture.seen[@intFromEnum(operation.Backend.aur)]);
    try std.testing.expect(capture.seen[@intFromEnum(operation.Backend.flatpak)]);
    try std.testing.expect(capture.seen[@intFromEnum(operation.Backend.appimage)]);
    try std.testing.expect(capture.seen[@intFromEnum(operation.Backend.local_package)]);
}

test "ALPM and AUR questions use the shared response hook" {
    const Responder = struct {
        questions: usize = 0,
        saw_alpm_provider: bool = false,

        fn answer(data: ?*anyopaque, question: operation.Question) operation.QuestionResponse {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.questions += 1;
            std.testing.expect(question.options.len == 2) catch unreachable;
            if (question.envelope.backend == .alpm) {
                std.testing.expect(question.kind == .select_provider) catch unreachable;
                std.testing.expectEqualStrings("second", question.options[1].description) catch unreachable;
                std.testing.expect(question.options[1].is_installed) catch unreachable;
                self.saw_alpm_provider = true;
            }
            return .{ .choice = 1 };
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var context = operation.OperationContext.init(std.testing.allocator, threaded.io());
    defer context.deinit();
    var responder: Responder = .{};
    context.setQuestionHandler(.{ .function = Responder.answer, .data = &responder });

    var alpm_operation = context.begin(.{ .backend = .alpm, .kind = .install });
    var alpm_dispatcher = alpm.events.Dispatcher.init(std.testing.allocator);
    defer alpm_dispatcher.deinit();
    alpm_dispatcher.setOperation(&alpm_operation);
    const alpm_response = alpm_dispatcher.raiseQuestion(threaded.io(), .{
        .question = "Select an ALPM provider",
        .question_type = @intFromEnum(alpm.bindings.libalpm.QuestionType.select_provider),
        .options = &.{ "provider-a", "provider-b" },
        .provider_options = &.{
            .{ .name = "provider-a", .description = "first", .is_installed = false },
            .{ .name = "provider-b", .description = "second", .is_installed = true },
        },
    });
    try std.testing.expectEqual(@as(?c_int, 1), alpm_response.choice);
    alpm_dispatcher.setOperation(null);
    alpm_operation.finish(.success);

    var aur_operation = context.begin(.{ .backend = .aur, .kind = .install });
    var aur_dispatcher = aur.events.Dispatcher.init(std.testing.allocator);
    defer aur_dispatcher.deinit();
    aur_dispatcher.setOperation(&aur_operation);
    const aur_response = aur_dispatcher.ask(.{
        .question_type = .select_provider,
        .question = "Select an AUR provider",
        .options = &.{
            .{ .name = "provider-a", .description = "first" },
            .{ .name = "provider-b", .description = "second" },
        },
    });
    try std.testing.expectEqualSlices(usize, &.{1}, aur_response.selected_indices);
    aur_dispatcher.setOperation(null);
    aur_operation.finish(.success);

    try std.testing.expectEqual(@as(usize, 2), responder.questions);
    try std.testing.expect(responder.saw_alpm_provider);
}

test {
    _ = @import("alpm/bindings.zig");
    _ = @import("alpm/bootstrap.zig");
    _ = @import("alpm/manager.zig");
    _ = @import("alpm/manager_test.zig");
    _ = @import("alpm/events.zig");
    _ = @import("alpm/configuration.zig");
    _ = @import("alpm/cache_manager.zig");
    _ = @import("alpm/archive_manager.zig");
    _ = @import("alpm/pacfile_manager.zig");
    _ = @import("alpm/distribution-hooks/CachyOS/update_notice.zig");
    _ = @import("alpm/distribution-hooks/os_utilities.zig");
    _ = @import("flatpak/types.zig");
    _ = @import("flatpak/backend_loader.zig");
    _ = @import("flatpak/client.zig");
    _ = @import("flatpak/errors.zig");
    _ = @import("flatpak/remote_manager.zig");
    _ = @import("flatpak/manager.zig");
    _ = @import("flatpak/eol.zig");
    _ = @import("flatpak/appstream_manager.zig");
    _ = @import("flatpak/appstream_parser.zig");
    _ = @import("flatpak/events.zig");
    _ = @import("appimage/manager.zig");
    _ = @import("archive");
    _ = @import("shared/downloader.zig");
    _ = @import("shared/source_pgp_verifier.zig");
    _ = @import("shared/source_pgp_keyring.zig");
    _ = @import("shared/package_signer.zig");
    _ = @import("appimage/update_manager.zig");
    _ = @import("pkgbuild/pkgbuild_parser.zig");
    _ = @import("pkgbuild/post_install_validator.zig");
    _ = @import("pkgbuild/install_script.zig");
    _ = @import("pkgbuild/install_script_scanner.zig");
    _ = @import("pkgbuild/homograph_validator.zig");
    _ = @import("aur/manager.zig");
    _ = @import("aur/builder/builder_test.zig");
    _ = @import("local/manager.zig");
    _ = @import("local/file_inspector.zig");
    _ = @import("local/xdg_integration.zig");
    _ = @import("local/events.zig");
    _ = @import("operation_context");
}

test "Flatpak public facade does not expose generated native bindings" {
    try std.testing.expect(!@hasDecl(flatpak, "bindings"));
    try std.testing.expect(!@hasDecl(flatpak, "backend_loader"));
    try std.testing.expect(!@hasDecl(flatpak.manager, "bindings"));
    _ = flatpak.Scope;
    _ = flatpak.RefKind;
    _ = flatpak.InstalledApplication;
    _ = flatpak.InstalledRef;
    _ = flatpak.Remote;
}
