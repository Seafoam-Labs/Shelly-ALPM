//! Shared, dependency-free diagnostics are also used by the standalone helpers.
const diagnostics = @import("diagnostics");

pub const Context = diagnostics.Context;
pub const flatpak_missing = diagnostics.flatpak_missing;
pub const flatpak_incompatible = diagnostics.flatpak_incompatible;
pub const authorization_denied = diagnostics.authorization_denied;
pub const unknown_cause = diagnostics.unknown_cause;
pub const allocation_failure = diagnostics.allocation_failure;
pub const format = diagnostics.format;
pub const formatEvent = diagnostics.formatEvent;
pub const alloc = diagnostics.alloc;
pub const cause = diagnostics.cause;
pub const isCancellation = diagnostics.isCancellation;
pub const isGenericDetail = diagnostics.isGenericDetail;
pub const operationDescription = diagnostics.operationDescription;
pub const operationAction = diagnostics.operationAction;
pub const safe = diagnostics.safe;
pub const sanitizeAlloc = diagnostics.sanitizeAlloc;
pub const missingPackage = diagnostics.missingPackage;
pub const databaseLocked = diagnostics.databaseLocked;
pub const buildFailed = diagnostics.buildFailed;

test {
    _ = diagnostics;
}
