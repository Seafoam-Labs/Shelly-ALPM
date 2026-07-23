const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

// Max depth is at most one for this configuration file.
// Why the hell would you ever want more than one of these???
const max_depth: usize = 1;

pub const MakePackageConfiguration = struct {
    // Starting with architecture flags as source acquisition isn't needed
    carch: []const u8,
    chost: []const u8,
    package_carch: []const u8,
    nproc: u8,
    cpp_flags: []const u8,
    c_flags: []const u8,
    cxx_flags: []const u8,
    ld_flags: []const u8,
    lto_flags: []const u8,
    make_flags: []const u8,
    ninja_flags: []const u8,
    debug_c_flags: []const u8,
    debug_cxx_flags: []const u8,
    // Build environment flags
    //
    // Makepkg defaults: BUILDENV=(!distcc !color !ccache check !sign)
    //  A negated environment option will do the opposite of the comments below.
    //
    //-- distcc:   Use the Distributed C/C++/ObjC compiler
    //-- color:    Colorize output messages
    //-- ccache:   Use ccache to cache compilation
    //-- check:    Run the check() function if present in the PKGBUILD
    //-- sign:     Generate PGP signature file
    build_environment: []const u8,
    //-- If using DistCC, your MAKEFLAGS will also need modification. In addition,
    //-- specify a space-delimited list of hosts running in the DistCC cluster.
    distributed_c_compiler_hosts: []const u8,
    build_directory: []const u8,
    // Global packaging options
    // Makepkg defaults:
    // OPTIONS=(!strip docs libtool staticlibs emptydirs !zipman !purge !debug !lto !autodeps)
    //  A negated option will do the opposite of the comments below.
    //-- strip:      Strip symbols from binaries/libraries
    //-- docs:       Save doc directories specified by DOC_DIRS
    //-- libtool:    Leave libtool (.la) files in packages
    //-- staticlibs: Leave static library (.a) files in packages
    //-- emptydirs:  Leave empty directories in packages
    //-- zipman:     Compress manual (man and info) pages in MAN_DIRS with gzip
    //-- purge:      Remove files specified by PURGE_TARGETS
    //-- debug:      Add debugging flags as specified in DEBUG_* variables
    //-- lto:        Add compile flags for building with link time optimization
    //-- autodeps:   Automatically add depends/provides
    options: []const u8,
    // File integrity checks to use. Valid: md5, sha1, sha224, sha256, sha384, sha512, b2
    integrity_check: []const u8,
    strip_binaries: []const u8,
    strip_static: []const u8,
    man_directories: []const u8,
    doc_directores: []const u8,
    purge_targets: []const u8,
    debug_source_direcctory: []const u8,
    library_directories: []const u8,
    // Package output options
    // Destination: specify a fixed directory where all packages will be placed
    package_destination: []const u8,
    // Source cache: specify a fixed directory where source files will be cached
    source_destination: []const u8,
    // Source packages: specify a fixed directory where all src packages will be placed
    source_package_destionation: []const u8,
    // Log files: specify a fixed directory where all log files will be placed
    log_destination: []const u8,
    // Packager: name/email of the person or organization building packages
    packager: []const u8,
    // Specific gpg key to use for package signing
    gpg_key: []const u8,
    // Compression defaults
    gz: []const u8,
    bz2: []const u8,
    xz: []const u8,
    zst: []const u8,
    lrz: []const u8,
    lzo: []const u8,
    z: []const u8,
    lz4: []const u8,
    lz: []const u8,
    // Extension defaults
    package_extension: []const u8,
    source_extension: []const u8,

    fn read_while_file(io: Io, alloc: Allocator, path: []const u8) ![]u8 {
        return Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    }

    const Parser = struct {
        io: Io,
        scratch_allocator: Allocator,
        arena_allocator: Allocator,
        config: *MakePackageConfiguration,
        depth: usize = 0,

        fn parse_file(self: *Parser, path: []const u8) Allocator.Error!void {
            if (self.depth >= max_depth) return;
            const bytes = read_while_file(self.io, self.scratch_allocator, path);
            defer self.scratch_allocator.free(bytes);
            self.depth += 1;
        }
    };
};
