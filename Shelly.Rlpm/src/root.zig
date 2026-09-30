//! Independent native package metadata and lifecycle API. Operational capability
//! reporting is intentionally narrower than the eventual libalpm target.
const builtin = @import("builtin");
pub const Workers = @import("workers");
pub const TransactionActions = @import("structs/TransactionActions.zig");
pub const Scriptlets = @import("structs/Scriptlets.zig");
pub const Hooks = @import("structs/Hooks.zig");
pub const ActionProcess = @import("structs/ActionProcess.zig");
pub const Downloads = @import("structs/Downloads.zig");
pub const Owner = @import("structs/Owner.zig");
pub const OwnerConfiguration = @import("structs/OwnerConfiguration.zig");
pub const Backend = @import("structs/Backend.zig").Backend;
pub const LocalBackend = @import("structs/LocalBackend.zig");
pub const SyncBackend = @import("structs/SyncBackend.zig");
pub const MemberReader = @import("structs/MemberReader.zig");
pub const Database = @import("structs/Database.zig");
pub const DatabaseConfiguration = @import("structs/DatabaseConfiguration.zig");
pub const DatabaseRef = @import("structs/DatabaseRef.zig");
pub const PackageRef = @import("structs/PackageRef.zig");
pub const Package = @import("structs/Package.zig");
pub const PackageFile = @import("structs/PackageFile.zig");
pub const BackupFile = @import("structs/BackupFile.zig");
pub const MtreeIterator = @import("structs/MtreeIterator.zig");
pub const PackageRelation = @import("structs/PackageRelation.zig");
pub const Version = @import("structs/Version.zig");
pub const ParsedDescription = @import("structs/ParsedDescription.zig");
pub const Group = @import("structs/Group.zig");
pub const SignaturePolicy = @import("structs/SignaturePolicy.zig");
pub const SignatureResult = @import("structs/SignatureResult.zig");
pub const Verification = @import("structs/Verification.zig");
pub const ImmutableFile = @import("structs/ImmutableFile.zig");
pub const Checksum = @import("structs/Checksum.zig");
pub const OpenPgp = @import("structs/OpenPgp.zig");
pub const DatabaseUsage = @import("structs/DatabaseUsage.zig");
pub const DatabaseStatus = @import("structs/DatabaseStatus.zig");
pub const Callbacks = @import("structs/Callbacks.zig");
pub const Diagnostic = @import("structs/Diagnostic.zig");
pub const PhysicalArchitectures = @import("structs/PhysicalArchitectures.zig");
pub const Resolver = @import("structs/Resolver.zig");
pub const TransactionPlan = @import("structs/TransactionPlan.zig");
pub const TransactionFlags = @import("structs/TransactionFlags.zig");
pub const Transaction = @import("structs/Transaction.zig");
pub const ExecutionManifest = @import("structs/ExecutionManifest.zig");
pub const PathPatterns = @import("structs/PathPatterns.zig");
pub const OwnedQuestion = @import("structs/OwnedQuestion.zig");
const DatabaseValidationTests = @import("structs/DatabaseValidationTests.zig");

pub const version = "0.0.0";

pub const Capabilities = struct {
    local_metadata: bool = true,
    archive_metadata: bool = true,
    version_comparison: bool = true,
    detached_signature_verification: bool = true,
    physical_architectures: bool = builtin.os.tag == .linux,
    sync_databases: bool = true,
    sqlite_sync_databases: bool = true,
    signature_policy_enforcement: bool = true,
    resolution_plans: bool = true,
    transaction_lifecycle: bool = true,
    downloads: bool = true,
    filesystem_preflight: bool = true,
    /// Hook/scriptlet execution and installed-state mutation are operational.
    transaction_actions: bool = true,
    transactions: bool = true,
    localization: bool = false,
};

pub fn capabilities() Capabilities {
    return .{};
}

test {
    _ = Owner;
    _ = OwnerConfiguration;
    _ = DatabaseConfiguration;
    _ = Version;
    _ = PackageRelation;
    _ = Package;
    _ = ParsedDescription;
    _ = Group;
    _ = DatabaseStatus;
    _ = DatabaseUsage;
    _ = SignaturePolicy;
    _ = Database;
    _ = PhysicalArchitectures;
    _ = DatabaseValidationTests;
}
