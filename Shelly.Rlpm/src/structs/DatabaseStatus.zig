const DatabaseStatus = @This();

pub const Presence = enum {
    unknown,
    exists,
    missing,
};

pub const Validation = enum {
    unchecked,
    valid,
    invalid,
};

presence: Presence = .unknown,
validation: Validation = .unchecked,

package_cache_loaded: bool = false,
group_cache_loaded: bool = false,

pub fn isUsable(self: DatabaseStatus) bool {
    return self.presence == .exists and
        self.validation == .valid;
}

pub fn markMissing(self: *DatabaseStatus) void {
    self.presence = .missing;
    self.validation = .unchecked;
    self.package_cache_loaded = false;
    self.group_cache_loaded = false;
}

pub fn markInvalid(self: *DatabaseStatus) void {
    self.presence = .exists;
    self.validation = .invalid;
    self.package_cache_loaded = false;
    self.group_cache_loaded = false;
}

pub fn markValid(self: *DatabaseStatus) void {
    self.presence = .exists;
    self.validation = .valid;
}

pub fn clearCaches(self: *DatabaseStatus) void {
    self.package_cache_loaded = false;
    self.group_cache_loaded = false;
}
