const __root = @This();
pub const __builtin = @import("std").zig.c_translation.builtins;
pub const __helpers = @import("std").zig.c_translation.helpers;
pub const __u_char = u8;
pub const __u_short = c_ushort;
pub const __u_int = c_uint;
pub const __u_long = c_ulong;
pub const __int8_t = i8;
pub const __uint8_t = u8;
pub const __int16_t = c_short;
pub const __uint16_t = c_ushort;
pub const __int32_t = c_int;
pub const __uint32_t = c_uint;
pub const __int64_t = c_long;
pub const __uint64_t = c_ulong;
pub const __int_least8_t = __int8_t;
pub const __uint_least8_t = __uint8_t;
pub const __int_least16_t = __int16_t;
pub const __uint_least16_t = __uint16_t;
pub const __int_least32_t = __int32_t;
pub const __uint_least32_t = __uint32_t;
pub const __int_least64_t = __int64_t;
pub const __uint_least64_t = __uint64_t;
pub const __quad_t = c_long;
pub const __u_quad_t = c_ulong;
pub const __intmax_t = c_long;
pub const __uintmax_t = c_ulong;
pub const __dev_t = c_ulong;
pub const __uid_t = c_uint;
pub const __gid_t = c_uint;
pub const __ino_t = c_ulong;
pub const __ino64_t = c_ulong;
pub const __mode_t = c_uint;
pub const __nlink_t = c_ulong;
pub const __off_t = c_long;
pub const __off64_t = c_long;
pub const __pid_t = c_int;
pub const __fsid_t = extern struct {
    __val: [2]c_int = @import("std").mem.zeroes([2]c_int),
};
pub const __clock_t = c_long;
pub const __rlim_t = c_ulong;
pub const __rlim64_t = c_ulong;
pub const __id_t = c_uint;
pub const __time_t = c_long;
pub const __useconds_t = c_uint;
pub const __suseconds_t = c_long;
pub const __suseconds64_t = c_long;
pub const __daddr_t = c_int;
pub const __key_t = c_int;
pub const __clockid_t = c_int;
pub const __timer_t = ?*anyopaque;
pub const __blksize_t = c_long;
pub const __blkcnt_t = c_long;
pub const __blkcnt64_t = c_long;
pub const __fsblkcnt_t = c_ulong;
pub const __fsblkcnt64_t = c_ulong;
pub const __fsfilcnt_t = c_ulong;
pub const __fsfilcnt64_t = c_ulong;
pub const __fsword_t = c_long;
pub const __ssize_t = c_long;
pub const __syscall_slong_t = c_long;
pub const __syscall_ulong_t = c_ulong;
pub const __loff_t = __off64_t;
pub const __caddr_t = [*c]u8;
pub const __intptr_t = c_long;
pub const __socklen_t = c_uint;
pub const __sig_atomic_t = c_int;
pub const int_least8_t = __int_least8_t;
pub const int_least16_t = __int_least16_t;
pub const int_least32_t = __int_least32_t;
pub const int_least64_t = __int_least64_t;
pub const uint_least8_t = __uint_least8_t;
pub const uint_least16_t = __uint_least16_t;
pub const uint_least32_t = __uint_least32_t;
pub const uint_least64_t = __uint_least64_t;
pub const int_fast8_t = i8;
pub const int_fast16_t = c_long;
pub const int_fast32_t = c_long;
pub const int_fast64_t = c_long;
pub const uint_fast8_t = u8;
pub const uint_fast16_t = c_ulong;
pub const uint_fast32_t = c_ulong;
pub const uint_fast64_t = c_ulong;
pub const intmax_t = __intmax_t;
pub const uintmax_t = __uintmax_t;
pub const u_char = __u_char;
pub const u_short = __u_short;
pub const u_int = __u_int;
pub const u_long = __u_long;
pub const quad_t = __quad_t;
pub const u_quad_t = __u_quad_t;
pub const fsid_t = __fsid_t;
pub const loff_t = __loff_t;
pub const ino_t = __ino_t;
pub const dev_t = __dev_t;
pub const gid_t = __gid_t;
pub const mode_t = __mode_t;
pub const nlink_t = __nlink_t;
pub const uid_t = __uid_t;
pub const off_t = __off_t;
pub const pid_t = __pid_t;
pub const id_t = __id_t;
pub const daddr_t = __daddr_t;
pub const caddr_t = __caddr_t;
pub const key_t = __key_t;
pub const clock_t = __clock_t;
pub const clockid_t = __clockid_t;
pub const time_t = __time_t;
pub const timer_t = __timer_t;
pub const ptrdiff_t = c_long;
pub const wchar_t = c_int;
pub const max_align_t = extern struct {
    __aro_max_align_ll: c_longlong = 0,
    __aro_max_align_ld: c_longdouble = 0,
};
pub const ulong = c_ulong;
pub const ushort = c_ushort;
pub const uint = c_uint;
pub const u_int8_t = __uint8_t;
pub const u_int16_t = __uint16_t;
pub const u_int32_t = __uint32_t;
pub const u_int64_t = __uint64_t;
pub const register_t = c_int;
pub fn __bswap_16(arg___bsx: __uint16_t) callconv(.c) __uint16_t {
    var __bsx = arg___bsx;
    _ = &__bsx;
    return @byteSwap(@as(__uint16_t, __bsx));
}
pub fn __bswap_32(arg___bsx: __uint32_t) callconv(.c) __uint32_t {
    var __bsx = arg___bsx;
    _ = &__bsx;
    return @bitCast(@as(c_int, @byteSwap(@as(c_int, @bitCast(@as(c_uint, @truncate(__bsx)))))));
}
pub fn __bswap_64(arg___bsx: __uint64_t) callconv(.c) __uint64_t {
    var __bsx = arg___bsx;
    _ = &__bsx;
    return @bitCast(@as(c_long, @byteSwap(@as(c_long, @bitCast(@as(c_ulong, @truncate(__bsx)))))));
}
pub fn __uint16_identity(arg___x: __uint16_t) callconv(.c) __uint16_t {
    var __x = arg___x;
    _ = &__x;
    return __x;
}
pub fn __uint32_identity(arg___x: __uint32_t) callconv(.c) __uint32_t {
    var __x = arg___x;
    _ = &__x;
    return __x;
}
pub fn __uint64_identity(arg___x: __uint64_t) callconv(.c) __uint64_t {
    var __x = arg___x;
    _ = &__x;
    return __x;
}
pub const __sigset_t = extern struct {
    __val: [16]c_ulong = @import("std").mem.zeroes([16]c_ulong),
};
pub const sigset_t = __sigset_t;
pub const struct_timeval = extern struct {
    tv_sec: __time_t = 0,
    tv_usec: __suseconds_t = 0,
};
pub const struct_timespec = extern struct {
    tv_sec: __time_t = 0,
    tv_nsec: __syscall_slong_t = 0,
    pub const nanosleep = __root.nanosleep;
    pub const timespec_get = __root.timespec_get;
    pub const get = __root.timespec_get;
};
pub const suseconds_t = __suseconds_t;
pub const __fd_mask = c_long;
pub const fd_set = extern struct {
    __fds_bits: [16]__fd_mask = @import("std").mem.zeroes([16]__fd_mask),
};
pub const fd_mask = __fd_mask;
pub extern fn select(__nfds: c_int, noalias __readfds: [*c]fd_set, noalias __writefds: [*c]fd_set, noalias __exceptfds: [*c]fd_set, noalias __timeout: [*c]struct_timeval) c_int;
pub extern fn pselect(__nfds: c_int, noalias __readfds: [*c]fd_set, noalias __writefds: [*c]fd_set, noalias __exceptfds: [*c]fd_set, noalias __timeout: [*c]const struct_timespec, noalias __sigmask: [*c]const __sigset_t) c_int;
pub const blksize_t = __blksize_t;
pub const blkcnt_t = __blkcnt_t;
pub const fsblkcnt_t = __fsblkcnt_t;
pub const fsfilcnt_t = __fsfilcnt_t;
const struct_unnamed_1 = extern struct {
    __low: c_uint = 0,
    __high: c_uint = 0,
};
pub const __atomic_wide_counter = extern union {
    __value64: c_ulonglong,
    __value32: struct_unnamed_1,
};
pub const struct___pthread_internal_list = extern struct {
    __prev: [*c]struct___pthread_internal_list = null,
    __next: [*c]struct___pthread_internal_list = null,
};
pub const __pthread_list_t = struct___pthread_internal_list;
pub const struct___pthread_internal_slist = extern struct {
    __next: [*c]struct___pthread_internal_slist = null,
};
pub const __pthread_slist_t = struct___pthread_internal_slist;
pub const struct___pthread_mutex_s = extern struct {
    __lock: c_int = 0,
    __count: c_uint = 0,
    __owner: c_int = 0,
    __nusers: c_uint = 0,
    __kind: c_int = 0,
    __spins: c_short = 0,
    __glibc_reserved: c_short = 0,
    __list: __pthread_list_t = @import("std").mem.zeroes(__pthread_list_t),
};
pub const struct___pthread_rwlock_arch_t = extern struct {
    __readers: c_uint = 0,
    __writers: c_uint = 0,
    __wrphase_futex: c_uint = 0,
    __writers_futex: c_uint = 0,
    __pad3: c_uint = 0,
    __pad4: c_uint = 0,
    __cur_writer: c_int = 0,
    __shared: c_int = 0,
    __pad1: c_ulong = 0,
    __pad2: c_ulong = 0,
    __flags: c_uint = 0,
};
pub const struct___pthread_cond_s = extern struct {
    __wseq: __atomic_wide_counter = @import("std").mem.zeroes(__atomic_wide_counter),
    __g1_start: __atomic_wide_counter = @import("std").mem.zeroes(__atomic_wide_counter),
    __g_size: [2]c_uint = @import("std").mem.zeroes([2]c_uint),
    __g1_orig_size: c_uint = 0,
    __wrefs: c_uint = 0,
    __g_signals: [2]c_uint = @import("std").mem.zeroes([2]c_uint),
    __unused_initialized_1: c_uint = 0,
    __unused_initialized_2: c_uint = 0,
};
pub const __tss_t = c_uint;
pub const __thrd_t = c_ulong;
pub const __once_flag = extern struct {
    __data: c_int = 0,
};
pub const pthread_t = c_ulong;
pub const pthread_mutexattr_t = extern union {
    __size: [4]u8,
    __align: c_int,
};
pub const pthread_condattr_t = extern union {
    __size: [4]u8,
    __align: c_int,
};
pub const pthread_key_t = c_uint;
pub const pthread_once_t = c_int;
pub const union_pthread_attr_t = extern union {
    __size: [56]u8,
    __align: c_long,
};
pub const pthread_attr_t = union_pthread_attr_t;
pub const pthread_mutex_t = extern union {
    __data: struct___pthread_mutex_s,
    __size: [40]u8,
    __align: c_long,
};
pub const pthread_cond_t = extern union {
    __data: struct___pthread_cond_s,
    __size: [48]u8,
    __align: c_longlong,
};
pub const pthread_rwlock_t = extern union {
    __data: struct___pthread_rwlock_arch_t,
    __size: [56]u8,
    __align: c_long,
};
pub const pthread_rwlockattr_t = extern union {
    __size: [8]u8,
    __align: c_long,
};
pub const pthread_spinlock_t = c_int;
pub const pthread_barrier_t = extern union {
    __size: [32]u8,
    __align: c_long,
};
pub const pthread_barrierattr_t = extern union {
    __size: [4]u8,
    __align: c_int,
};
pub const struct___va_list_tag_2 = extern struct {
    unnamed_0: c_uint = 0,
    unnamed_1: c_uint = 0,
    unnamed_2: ?*anyopaque = null,
    unnamed_3: ?*anyopaque = null,
};
pub const __builtin_va_list = [1]struct___va_list_tag_2;
pub const va_list = __builtin_va_list;
pub const __gnuc_va_list = __builtin_va_list;
pub const struct_stat = extern struct {
    st_dev: __dev_t = 0,
    st_ino: __ino_t = 0,
    st_nlink: __nlink_t = 0,
    st_mode: __mode_t = 0,
    st_uid: __uid_t = 0,
    st_gid: __gid_t = 0,
    __pad0: c_int = 0,
    st_rdev: __dev_t = 0,
    st_size: __off_t = 0,
    st_blksize: __blksize_t = 0,
    st_blocks: __blkcnt_t = 0,
    st_atim: struct_timespec = @import("std").mem.zeroes(struct_timespec),
    st_mtim: struct_timespec = @import("std").mem.zeroes(struct_timespec),
    st_ctim: struct_timespec = @import("std").mem.zeroes(struct_timespec),
    __glibc_reserved: [3]__syscall_slong_t = @import("std").mem.zeroes([3]__syscall_slong_t),
};
pub extern fn stat(noalias __file: [*c]const u8, noalias __buf: [*c]struct_stat) c_int;
pub extern fn fstat(__fd: c_int, __buf: [*c]struct_stat) c_int;
pub extern fn fstatat(__fd: c_int, noalias __file: [*c]const u8, noalias __buf: [*c]struct_stat, __flag: c_int) c_int;
pub extern fn lstat(noalias __file: [*c]const u8, noalias __buf: [*c]struct_stat) c_int;
pub extern fn chmod(__file: [*c]const u8, __mode: __mode_t) c_int;
pub extern fn lchmod(__file: [*c]const u8, __mode: __mode_t) c_int;
pub extern fn fchmod(__fd: c_int, __mode: __mode_t) c_int;
pub extern fn fchmodat(__fd: c_int, __file: [*c]const u8, __mode: __mode_t, __flag: c_int) c_int;
pub extern fn umask(__mask: __mode_t) __mode_t;
pub extern fn mkdir(__path: [*c]const u8, __mode: __mode_t) c_int;
pub extern fn mkdirat(__fd: c_int, __path: [*c]const u8, __mode: __mode_t) c_int;
pub extern fn mknod(__path: [*c]const u8, __mode: __mode_t, __dev: __dev_t) c_int;
pub extern fn mknodat(__fd: c_int, __path: [*c]const u8, __mode: __mode_t, __dev: __dev_t) c_int;
pub extern fn mkfifo(__path: [*c]const u8, __mode: __mode_t) c_int;
pub extern fn mkfifoat(__fd: c_int, __path: [*c]const u8, __mode: __mode_t) c_int;
pub extern fn utimensat(__fd: c_int, __path: [*c]const u8, __times: [*c]const struct_timespec, __flags: c_int) c_int;
pub extern fn futimens(__fd: c_int, __times: [*c]const struct_timespec) c_int;
const union_unnamed_3 = extern union {
    __wch: c_uint,
    __wchb: [4]u8,
};
pub const __mbstate_t = extern struct {
    __count: c_int = 0,
    __value: union_unnamed_3 = @import("std").mem.zeroes(union_unnamed_3),
};
pub const struct__G_fpos_t = extern struct {
    __pos: __off_t = 0,
    __state: __mbstate_t = @import("std").mem.zeroes(__mbstate_t),
};
pub const __fpos_t = struct__G_fpos_t;
pub const struct__G_fpos64_t = extern struct {
    __pos: __off64_t = 0,
    __state: __mbstate_t = @import("std").mem.zeroes(__mbstate_t),
};
pub const __fpos64_t = struct__G_fpos64_t;
pub const struct__IO_marker = opaque {}; // /usr/include/bits/types/struct_FILE.h:75:7: warning: struct demoted to opaque type - has bitfield
pub const struct__IO_FILE = opaque {
    pub const fclose = __root.fclose;
    pub const fflush = __root.fflush;
    pub const fflush_unlocked = __root.fflush_unlocked;
    pub const setbuf = __root.setbuf;
    pub const setvbuf = __root.setvbuf;
    pub const setbuffer = __root.setbuffer;
    pub const setlinebuf = __root.setlinebuf;
    pub const fprintf = __root.fprintf;
    pub const vfprintf = __root.vfprintf;
    pub const fscanf = __root.fscanf;
    pub const vfscanf = __root.vfscanf;
    pub const fgetc = __root.fgetc;
    pub const getc = __root.getc;
    pub const getc_unlocked = __root.getc_unlocked;
    pub const fgetc_unlocked = __root.fgetc_unlocked;
    pub const getw = __root.getw;
    pub const fseek = __root.fseek;
    pub const ftell = __root.ftell;
    pub const rewind = __root.rewind;
    pub const fseeko = __root.fseeko;
    pub const ftello = __root.ftello;
    pub const fgetpos = __root.fgetpos;
    pub const fsetpos = __root.fsetpos;
    pub const clearerr = __root.clearerr;
    pub const feof = __root.feof;
    pub const ferror = __root.ferror;
    pub const clearerr_unlocked = __root.clearerr_unlocked;
    pub const feof_unlocked = __root.feof_unlocked;
    pub const ferror_unlocked = __root.ferror_unlocked;
    pub const fileno = __root.fileno;
    pub const fileno_unlocked = __root.fileno_unlocked;
    pub const pclose = __root.pclose;
    pub const flockfile = __root.flockfile;
    pub const ftrylockfile = __root.ftrylockfile;
    pub const funlockfile = __root.funlockfile;
    pub const __uflow = __root.__uflow;
    pub const __overflow = __root.__overflow;
    pub const unlocked = __root.fflush_unlocked;
    pub const uflow = __root.__uflow;
    pub const overflow = __root.__overflow;
};
pub const __FILE = struct__IO_FILE;
pub const FILE = struct__IO_FILE;
pub const struct__IO_codecvt = opaque {};
pub const struct__IO_wide_data = opaque {};
pub const _IO_lock_t = anyopaque;
pub const cookie_read_function_t = fn (__cookie: ?*anyopaque, __buf: [*c]u8, __nbytes: usize) callconv(.c) __ssize_t;
pub const cookie_write_function_t = fn (__cookie: ?*anyopaque, __buf: [*c]const u8, __nbytes: usize) callconv(.c) __ssize_t;
pub const cookie_seek_function_t = fn (__cookie: ?*anyopaque, __pos: [*c]__off64_t, __w: c_int) callconv(.c) c_int;
pub const cookie_close_function_t = fn (__cookie: ?*anyopaque) callconv(.c) c_int;
pub const struct__IO_cookie_io_functions_t = extern struct {
    read: ?*const cookie_read_function_t = null,
    write: ?*const cookie_write_function_t = null,
    seek: ?*const cookie_seek_function_t = null,
    close: ?*const cookie_close_function_t = null,
};
pub const cookie_io_functions_t = struct__IO_cookie_io_functions_t;
pub const fpos_t = __fpos_t;
pub extern var stdin: ?*FILE;
pub extern var stdout: ?*FILE;
pub extern var stderr: ?*FILE;
pub extern fn remove(__filename: [*c]const u8) c_int;
pub extern fn rename(__old: [*c]const u8, __new: [*c]const u8) c_int;
pub extern fn renameat(__oldfd: c_int, __old: [*c]const u8, __newfd: c_int, __new: [*c]const u8) c_int;
pub extern fn fclose(__stream: ?*FILE) c_int;
pub extern fn tmpfile() ?*FILE;
pub extern fn tmpnam([*c]u8) [*c]u8;
pub extern fn tmpnam_r(__s: [*c]u8) [*c]u8;
pub extern fn tempnam(__dir: [*c]const u8, __pfx: [*c]const u8) [*c]u8;
pub extern fn fflush(__stream: ?*FILE) c_int;
pub extern fn fflush_unlocked(__stream: ?*FILE) c_int;
pub extern fn fopen(noalias __filename: [*c]const u8, noalias __modes: [*c]const u8) ?*FILE;
pub extern fn freopen(noalias __filename: [*c]const u8, noalias __modes: [*c]const u8, noalias __stream: ?*FILE) ?*FILE;
pub extern fn fdopen(__fd: c_int, __modes: [*c]const u8) ?*FILE;
pub extern fn fopencookie(noalias __magic_cookie: ?*anyopaque, noalias __modes: [*c]const u8, __io_funcs: cookie_io_functions_t) ?*FILE;
pub extern fn fmemopen(__s: ?*anyopaque, __len: usize, __modes: [*c]const u8) ?*FILE;
pub extern fn open_memstream(__bufloc: [*c][*c]u8, __sizeloc: [*c]usize) ?*FILE;
pub extern fn setbuf(noalias __stream: ?*FILE, noalias __buf: [*c]u8) void;
pub extern fn setvbuf(noalias __stream: ?*FILE, noalias __buf: [*c]u8, __modes: c_int, __n: usize) c_int;
pub extern fn setbuffer(noalias __stream: ?*FILE, noalias __buf: [*c]u8, __size: usize) void;
pub extern fn setlinebuf(__stream: ?*FILE) void;
pub extern fn fprintf(noalias __stream: ?*FILE, noalias __format: [*c]const u8, ...) c_int;
pub extern fn printf(noalias __format: [*c]const u8, ...) c_int;
pub extern fn sprintf(noalias __s: [*c]u8, noalias __format: [*c]const u8, ...) c_int;
pub extern fn vfprintf(noalias __s: ?*FILE, noalias __format: [*c]const u8, __arg: [*c]struct___va_list_tag_2) c_int;
pub extern fn vprintf(noalias __format: [*c]const u8, __arg: [*c]struct___va_list_tag_2) c_int;
pub extern fn vsprintf(noalias __s: [*c]u8, noalias __format: [*c]const u8, __arg: [*c]struct___va_list_tag_2) c_int;
pub extern fn snprintf(noalias __s: [*c]u8, __maxlen: usize, noalias __format: [*c]const u8, ...) c_int;
pub extern fn vsnprintf(noalias __s: [*c]u8, __maxlen: usize, noalias __format: [*c]const u8, __arg: [*c]struct___va_list_tag_2) c_int;
pub extern fn vasprintf(noalias __ptr: [*c][*c]u8, noalias __f: [*c]const u8, __arg: [*c]struct___va_list_tag_2) c_int;
pub extern fn __asprintf(noalias __ptr: [*c][*c]u8, noalias __fmt: [*c]const u8, ...) c_int;
pub extern fn asprintf(noalias __ptr: [*c][*c]u8, noalias __fmt: [*c]const u8, ...) c_int;
pub extern fn vdprintf(__fd: c_int, noalias __fmt: [*c]const u8, __arg: [*c]struct___va_list_tag_2) c_int;
pub extern fn dprintf(__fd: c_int, noalias __fmt: [*c]const u8, ...) c_int;
pub extern fn fscanf(noalias __stream: ?*FILE, noalias __format: [*c]const u8, ...) c_int;
pub extern fn scanf(noalias __format: [*c]const u8, ...) c_int;
pub extern fn sscanf(noalias __s: [*c]const u8, noalias __format: [*c]const u8, ...) c_int;
pub extern fn vfscanf(noalias __s: ?*FILE, noalias __format: [*c]const u8, __arg: [*c]struct___va_list_tag_2) c_int;
pub extern fn vscanf(noalias __format: [*c]const u8, __arg: [*c]struct___va_list_tag_2) c_int;
pub extern fn vsscanf(noalias __s: [*c]const u8, noalias __format: [*c]const u8, __arg: [*c]struct___va_list_tag_2) c_int;
pub extern fn fgetc(__stream: ?*FILE) c_int;
pub extern fn getc(__stream: ?*FILE) c_int;
pub extern fn getchar() c_int;
pub extern fn getc_unlocked(__stream: ?*FILE) c_int;
pub extern fn getchar_unlocked() c_int;
pub extern fn fgetc_unlocked(__stream: ?*FILE) c_int;
pub extern fn fputc(__c: c_int, __stream: ?*FILE) c_int;
pub extern fn putc(__c: c_int, __stream: ?*FILE) c_int;
pub extern fn putchar(__c: c_int) c_int;
pub extern fn fputc_unlocked(__c: c_int, __stream: ?*FILE) c_int;
pub extern fn putc_unlocked(__c: c_int, __stream: ?*FILE) c_int;
pub extern fn putchar_unlocked(__c: c_int) c_int;
pub extern fn getw(__stream: ?*FILE) c_int;
pub extern fn putw(__w: c_int, __stream: ?*FILE) c_int;
pub extern fn fgets(noalias __s: [*c]u8, __n: c_int, noalias __stream: ?*FILE) [*c]u8;
pub extern fn __getdelim(noalias __lineptr: [*c][*c]u8, noalias __n: [*c]usize, __delimiter: c_int, noalias __stream: ?*FILE) __ssize_t;
pub extern fn getdelim(noalias __lineptr: [*c][*c]u8, noalias __n: [*c]usize, __delimiter: c_int, noalias __stream: ?*FILE) __ssize_t;
pub extern fn getline(noalias __lineptr: [*c][*c]u8, noalias __n: [*c]usize, noalias __stream: ?*FILE) __ssize_t;
pub extern fn fputs(noalias __s: [*c]const u8, noalias __stream: ?*FILE) c_int;
pub extern fn puts(__s: [*c]const u8) c_int;
pub extern fn ungetc(__c: c_int, __stream: ?*FILE) c_int;
pub extern fn fread(noalias __ptr: ?*anyopaque, __size: usize, __n: usize, noalias __stream: ?*FILE) usize;
pub extern fn fwrite(noalias __ptr: ?*const anyopaque, __size: usize, __n: usize, noalias __s: ?*FILE) usize;
pub extern fn fread_unlocked(noalias __ptr: ?*anyopaque, __size: usize, __n: usize, noalias __stream: ?*FILE) usize;
pub extern fn fwrite_unlocked(noalias __ptr: ?*const anyopaque, __size: usize, __n: usize, noalias __stream: ?*FILE) usize;
pub extern fn fseek(__stream: ?*FILE, __off: c_long, __whence: c_int) c_int;
pub extern fn ftell(__stream: ?*FILE) c_long;
pub extern fn rewind(__stream: ?*FILE) void;
pub extern fn fseeko(__stream: ?*FILE, __off: __off_t, __whence: c_int) c_int;
pub extern fn ftello(__stream: ?*FILE) __off_t;
pub extern fn fgetpos(noalias __stream: ?*FILE, noalias __pos: [*c]fpos_t) c_int;
pub extern fn fsetpos(__stream: ?*FILE, __pos: [*c]const fpos_t) c_int;
pub extern fn clearerr(__stream: ?*FILE) void;
pub extern fn feof(__stream: ?*FILE) c_int;
pub extern fn ferror(__stream: ?*FILE) c_int;
pub extern fn clearerr_unlocked(__stream: ?*FILE) void;
pub extern fn feof_unlocked(__stream: ?*FILE) c_int;
pub extern fn ferror_unlocked(__stream: ?*FILE) c_int;
pub extern fn perror(__s: [*c]const u8) void;
pub extern fn fileno(__stream: ?*FILE) c_int;
pub extern fn fileno_unlocked(__stream: ?*FILE) c_int;
pub extern fn pclose(__stream: ?*FILE) c_int;
pub extern fn popen(__command: [*c]const u8, __modes: [*c]const u8) ?*FILE;
pub extern fn ctermid(__s: [*c]u8) [*c]u8;
pub extern fn flockfile(__stream: ?*FILE) void;
pub extern fn ftrylockfile(__stream: ?*FILE) c_int;
pub extern fn funlockfile(__stream: ?*FILE) void;
pub extern fn __uflow(?*FILE) c_int;
pub extern fn __overflow(?*FILE, c_int) c_int;
pub const struct_tm = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    tm_mon: c_int = 0,
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = 0,
    tm_gmtoff: c_long = 0,
    tm_zone: [*c]const u8 = null,
    pub const mktime = __root.mktime;
    pub const asctime = __root.asctime;
    pub const asctime_r = __root.asctime_r;
    pub const timegm = __root.timegm;
    pub const timelocal = __root.timelocal;
    pub const r = __root.asctime_r;
};
pub const struct_itimerspec = extern struct {
    it_interval: struct_timespec = @import("std").mem.zeroes(struct_timespec),
    it_value: struct_timespec = @import("std").mem.zeroes(struct_timespec),
};
pub const struct_sigevent = opaque {};
pub const struct___locale_data_4 = opaque {};
pub const struct___locale_struct = extern struct {
    __locales: [13]?*struct___locale_data_4 = @import("std").mem.zeroes([13]?*struct___locale_data_4),
    __ctype_b: [*c]const c_ushort = null,
    __ctype_tolower: [*c]const c_int = null,
    __ctype_toupper: [*c]const c_int = null,
    __names: [13][*c]const u8 = @import("std").mem.zeroes([13][*c]const u8),
};
pub const __locale_t = [*c]struct___locale_struct;
pub const locale_t = __locale_t;
pub extern fn clock() clock_t;
pub extern fn time(__timer: [*c]time_t) time_t;
pub extern fn difftime(__time1: time_t, __time0: time_t) f64;
pub extern fn mktime(__tp: [*c]struct_tm) time_t;
pub extern fn strftime(noalias __s: [*c]u8, __maxsize: usize, noalias __format: [*c]const u8, noalias __tp: [*c]const struct_tm) usize;
pub extern fn strftime_l(noalias __s: [*c]u8, __maxsize: usize, noalias __format: [*c]const u8, noalias __tp: [*c]const struct_tm, __loc: locale_t) usize;
pub extern fn gmtime(__timer: [*c]const time_t) [*c]struct_tm;
pub extern fn localtime(__timer: [*c]const time_t) [*c]struct_tm;
pub extern fn gmtime_r(noalias __timer: [*c]const time_t, noalias __tp: [*c]struct_tm) [*c]struct_tm;
pub extern fn localtime_r(noalias __timer: [*c]const time_t, noalias __tp: [*c]struct_tm) [*c]struct_tm;
pub extern fn asctime(__tp: [*c]const struct_tm) [*c]u8;
pub extern fn ctime(__timer: [*c]const time_t) [*c]u8;
pub extern fn asctime_r(noalias __tp: [*c]const struct_tm, noalias __buf: [*c]u8) [*c]u8;
pub extern fn ctime_r(noalias __timer: [*c]const time_t, noalias __buf: [*c]u8) [*c]u8;
pub extern var __tzname: [2][*c]u8;
pub extern var __daylight: c_int;
pub extern var __timezone: c_long;
pub extern var tzname: [2][*c]u8;
pub extern fn tzset() void;
pub extern var daylight: c_int;
pub extern var timezone: c_long;
pub extern fn timegm(__tp: [*c]struct_tm) time_t;
pub extern fn timelocal(__tp: [*c]struct_tm) time_t;
pub extern fn dysize(__year: c_int) c_int;
pub extern fn nanosleep(__requested_time: [*c]const struct_timespec, __remaining: [*c]struct_timespec) c_int;
pub extern fn clock_getres(__clock_id: clockid_t, __res: [*c]struct_timespec) c_int;
pub extern fn clock_gettime(__clock_id: clockid_t, __tp: [*c]struct_timespec) c_int;
pub extern fn clock_settime(__clock_id: clockid_t, __tp: [*c]const struct_timespec) c_int;
pub extern fn clock_nanosleep(__clock_id: clockid_t, __flags: c_int, __req: [*c]const struct_timespec, __rem: [*c]struct_timespec) c_int;
pub extern fn clock_getcpuclockid(__pid: pid_t, __clock_id: [*c]clockid_t) c_int;
pub extern fn timer_create(__clock_id: clockid_t, noalias __evp: ?*struct_sigevent, noalias __timerid: [*c]timer_t) c_int;
pub extern fn timer_delete(__timerid: timer_t) c_int;
pub extern fn timer_settime(__timerid: timer_t, __flags: c_int, noalias __value: [*c]const struct_itimerspec, noalias __ovalue: [*c]struct_itimerspec) c_int;
pub extern fn timer_gettime(__timerid: timer_t, __value: [*c]struct_itimerspec) c_int;
pub extern fn timer_getoverrun(__timerid: timer_t) c_int;
pub extern fn timespec_get(__ts: [*c]struct_timespec, __base: c_int) c_int;
pub const __gwchar_t = c_int;
pub const imaxdiv_t = extern struct {
    quot: c_long = 0,
    rem: c_long = 0,
};
pub extern fn imaxabs(__n: intmax_t) intmax_t;
pub extern fn imaxdiv(__numer: intmax_t, __denom: intmax_t) imaxdiv_t;
pub extern fn strtoimax(noalias __nptr: [*c]const u8, noalias __endptr: [*c][*c]u8, __base: c_int) intmax_t;
pub extern fn strtoumax(noalias __nptr: [*c]const u8, noalias __endptr: [*c][*c]u8, __base: c_int) uintmax_t;
pub extern fn wcstoimax(noalias __nptr: [*c]const __gwchar_t, noalias __endptr: [*c][*c]__gwchar_t, __base: c_int) intmax_t;
pub extern fn wcstoumax(noalias __nptr: [*c]const __gwchar_t, noalias __endptr: [*c][*c]__gwchar_t, __base: c_int) uintmax_t;
pub const useconds_t = __useconds_t;
pub const socklen_t = __socklen_t;
pub extern fn access(__name: [*c]const u8, __type: c_int) c_int;
pub extern fn faccessat(__fd: c_int, __file: [*c]const u8, __type: c_int, __flag: c_int) c_int;
pub extern fn lseek(__fd: c_int, __offset: __off_t, __whence: c_int) __off_t;
pub extern fn close(__fd: c_int) c_int;
pub extern fn closefrom(__lowfd: c_int) void;
pub extern fn read(__fd: c_int, __buf: ?*anyopaque, __nbytes: usize) isize;
pub extern fn write(__fd: c_int, __buf: ?*const anyopaque, __n: usize) isize;
pub extern fn pread(__fd: c_int, __buf: ?*anyopaque, __nbytes: usize, __offset: __off_t) isize;
pub extern fn pwrite(__fd: c_int, __buf: ?*const anyopaque, __n: usize, __offset: __off_t) isize;
pub extern fn pipe(__pipedes: [*c]c_int) c_int;
pub extern fn alarm(__seconds: c_uint) c_uint;
pub extern fn sleep(__seconds: c_uint) c_uint;
pub extern fn ualarm(__value: __useconds_t, __interval: __useconds_t) __useconds_t;
pub extern fn usleep(__useconds: __useconds_t) c_int;
pub extern fn pause() c_int;
pub extern fn chown(__file: [*c]const u8, __owner: __uid_t, __group: __gid_t) c_int;
pub extern fn fchown(__fd: c_int, __owner: __uid_t, __group: __gid_t) c_int;
pub extern fn lchown(__file: [*c]const u8, __owner: __uid_t, __group: __gid_t) c_int;
pub extern fn fchownat(__fd: c_int, __file: [*c]const u8, __owner: __uid_t, __group: __gid_t, __flag: c_int) c_int;
pub extern fn chdir(__path: [*c]const u8) c_int;
pub extern fn fchdir(__fd: c_int) c_int;
pub extern fn getcwd(__buf: [*c]u8, __size: usize) [*c]u8;
pub extern fn getwd(__buf: [*c]u8) [*c]u8;
pub extern fn dup(__fd: c_int) c_int;
pub extern fn dup2(__fd: c_int, __fd2: c_int) c_int;
pub extern var __environ: [*c][*c]u8;
pub extern fn execve(__path: [*c]const u8, __argv: [*c]const [*c]u8, __envp: [*c]const [*c]u8) c_int;
pub extern fn fexecve(__fd: c_int, __argv: [*c]const [*c]u8, __envp: [*c]const [*c]u8) c_int;
pub extern fn execv(__path: [*c]const u8, __argv: [*c]const [*c]u8) c_int;
pub extern fn execle(__path: [*c]const u8, __arg: [*c]const u8, ...) c_int;
pub extern fn execl(__path: [*c]const u8, __arg: [*c]const u8, ...) c_int;
pub extern fn execvp(__file: [*c]const u8, __argv: [*c]const [*c]u8) c_int;
pub extern fn execlp(__file: [*c]const u8, __arg: [*c]const u8, ...) c_int;
pub extern fn nice(__inc: c_int) c_int;
pub extern fn _exit(__status: c_int) noreturn;
pub const _PC_LINK_MAX: c_int = 0;
pub const _PC_MAX_CANON: c_int = 1;
pub const _PC_MAX_INPUT: c_int = 2;
pub const _PC_NAME_MAX: c_int = 3;
pub const _PC_PATH_MAX: c_int = 4;
pub const _PC_PIPE_BUF: c_int = 5;
pub const _PC_CHOWN_RESTRICTED: c_int = 6;
pub const _PC_NO_TRUNC: c_int = 7;
pub const _PC_VDISABLE: c_int = 8;
pub const _PC_SYNC_IO: c_int = 9;
pub const _PC_ASYNC_IO: c_int = 10;
pub const _PC_PRIO_IO: c_int = 11;
pub const _PC_SOCK_MAXBUF: c_int = 12;
pub const _PC_FILESIZEBITS: c_int = 13;
pub const _PC_REC_INCR_XFER_SIZE: c_int = 14;
pub const _PC_REC_MAX_XFER_SIZE: c_int = 15;
pub const _PC_REC_MIN_XFER_SIZE: c_int = 16;
pub const _PC_REC_XFER_ALIGN: c_int = 17;
pub const _PC_ALLOC_SIZE_MIN: c_int = 18;
pub const _PC_SYMLINK_MAX: c_int = 19;
pub const _PC_2_SYMLINKS: c_int = 20;
const enum_unnamed_5 = c_uint;
pub const _SC_ARG_MAX: c_int = 0;
pub const _SC_CHILD_MAX: c_int = 1;
pub const _SC_CLK_TCK: c_int = 2;
pub const _SC_NGROUPS_MAX: c_int = 3;
pub const _SC_OPEN_MAX: c_int = 4;
pub const _SC_STREAM_MAX: c_int = 5;
pub const _SC_TZNAME_MAX: c_int = 6;
pub const _SC_JOB_CONTROL: c_int = 7;
pub const _SC_SAVED_IDS: c_int = 8;
pub const _SC_REALTIME_SIGNALS: c_int = 9;
pub const _SC_PRIORITY_SCHEDULING: c_int = 10;
pub const _SC_TIMERS: c_int = 11;
pub const _SC_ASYNCHRONOUS_IO: c_int = 12;
pub const _SC_PRIORITIZED_IO: c_int = 13;
pub const _SC_SYNCHRONIZED_IO: c_int = 14;
pub const _SC_FSYNC: c_int = 15;
pub const _SC_MAPPED_FILES: c_int = 16;
pub const _SC_MEMLOCK: c_int = 17;
pub const _SC_MEMLOCK_RANGE: c_int = 18;
pub const _SC_MEMORY_PROTECTION: c_int = 19;
pub const _SC_MESSAGE_PASSING: c_int = 20;
pub const _SC_SEMAPHORES: c_int = 21;
pub const _SC_SHARED_MEMORY_OBJECTS: c_int = 22;
pub const _SC_AIO_LISTIO_MAX: c_int = 23;
pub const _SC_AIO_MAX: c_int = 24;
pub const _SC_AIO_PRIO_DELTA_MAX: c_int = 25;
pub const _SC_DELAYTIMER_MAX: c_int = 26;
pub const _SC_MQ_OPEN_MAX: c_int = 27;
pub const _SC_MQ_PRIO_MAX: c_int = 28;
pub const _SC_VERSION: c_int = 29;
pub const _SC_PAGESIZE: c_int = 30;
pub const _SC_RTSIG_MAX: c_int = 31;
pub const _SC_SEM_NSEMS_MAX: c_int = 32;
pub const _SC_SEM_VALUE_MAX: c_int = 33;
pub const _SC_SIGQUEUE_MAX: c_int = 34;
pub const _SC_TIMER_MAX: c_int = 35;
pub const _SC_BC_BASE_MAX: c_int = 36;
pub const _SC_BC_DIM_MAX: c_int = 37;
pub const _SC_BC_SCALE_MAX: c_int = 38;
pub const _SC_BC_STRING_MAX: c_int = 39;
pub const _SC_COLL_WEIGHTS_MAX: c_int = 40;
pub const _SC_EQUIV_CLASS_MAX: c_int = 41;
pub const _SC_EXPR_NEST_MAX: c_int = 42;
pub const _SC_LINE_MAX: c_int = 43;
pub const _SC_RE_DUP_MAX: c_int = 44;
pub const _SC_CHARCLASS_NAME_MAX: c_int = 45;
pub const _SC_2_VERSION: c_int = 46;
pub const _SC_2_C_BIND: c_int = 47;
pub const _SC_2_C_DEV: c_int = 48;
pub const _SC_2_FORT_DEV: c_int = 49;
pub const _SC_2_FORT_RUN: c_int = 50;
pub const _SC_2_SW_DEV: c_int = 51;
pub const _SC_2_LOCALEDEF: c_int = 52;
pub const _SC_PII: c_int = 53;
pub const _SC_PII_XTI: c_int = 54;
pub const _SC_PII_SOCKET: c_int = 55;
pub const _SC_PII_INTERNET: c_int = 56;
pub const _SC_PII_OSI: c_int = 57;
pub const _SC_POLL: c_int = 58;
pub const _SC_SELECT: c_int = 59;
pub const _SC_UIO_MAXIOV: c_int = 60;
pub const _SC_IOV_MAX: c_int = 60;
pub const _SC_PII_INTERNET_STREAM: c_int = 61;
pub const _SC_PII_INTERNET_DGRAM: c_int = 62;
pub const _SC_PII_OSI_COTS: c_int = 63;
pub const _SC_PII_OSI_CLTS: c_int = 64;
pub const _SC_PII_OSI_M: c_int = 65;
pub const _SC_T_IOV_MAX: c_int = 66;
pub const _SC_THREADS: c_int = 67;
pub const _SC_THREAD_SAFE_FUNCTIONS: c_int = 68;
pub const _SC_GETGR_R_SIZE_MAX: c_int = 69;
pub const _SC_GETPW_R_SIZE_MAX: c_int = 70;
pub const _SC_LOGIN_NAME_MAX: c_int = 71;
pub const _SC_TTY_NAME_MAX: c_int = 72;
pub const _SC_THREAD_DESTRUCTOR_ITERATIONS: c_int = 73;
pub const _SC_THREAD_KEYS_MAX: c_int = 74;
pub const _SC_THREAD_STACK_MIN: c_int = 75;
pub const _SC_THREAD_THREADS_MAX: c_int = 76;
pub const _SC_THREAD_ATTR_STACKADDR: c_int = 77;
pub const _SC_THREAD_ATTR_STACKSIZE: c_int = 78;
pub const _SC_THREAD_PRIORITY_SCHEDULING: c_int = 79;
pub const _SC_THREAD_PRIO_INHERIT: c_int = 80;
pub const _SC_THREAD_PRIO_PROTECT: c_int = 81;
pub const _SC_THREAD_PROCESS_SHARED: c_int = 82;
pub const _SC_NPROCESSORS_CONF: c_int = 83;
pub const _SC_NPROCESSORS_ONLN: c_int = 84;
pub const _SC_PHYS_PAGES: c_int = 85;
pub const _SC_AVPHYS_PAGES: c_int = 86;
pub const _SC_ATEXIT_MAX: c_int = 87;
pub const _SC_PASS_MAX: c_int = 88;
pub const _SC_XOPEN_VERSION: c_int = 89;
pub const _SC_XOPEN_XCU_VERSION: c_int = 90;
pub const _SC_XOPEN_UNIX: c_int = 91;
pub const _SC_XOPEN_CRYPT: c_int = 92;
pub const _SC_XOPEN_ENH_I18N: c_int = 93;
pub const _SC_XOPEN_SHM: c_int = 94;
pub const _SC_2_CHAR_TERM: c_int = 95;
pub const _SC_2_C_VERSION: c_int = 96;
pub const _SC_2_UPE: c_int = 97;
pub const _SC_XOPEN_XPG2: c_int = 98;
pub const _SC_XOPEN_XPG3: c_int = 99;
pub const _SC_XOPEN_XPG4: c_int = 100;
pub const _SC_CHAR_BIT: c_int = 101;
pub const _SC_CHAR_MAX: c_int = 102;
pub const _SC_CHAR_MIN: c_int = 103;
pub const _SC_INT_MAX: c_int = 104;
pub const _SC_INT_MIN: c_int = 105;
pub const _SC_LONG_BIT: c_int = 106;
pub const _SC_WORD_BIT: c_int = 107;
pub const _SC_MB_LEN_MAX: c_int = 108;
pub const _SC_NZERO: c_int = 109;
pub const _SC_SSIZE_MAX: c_int = 110;
pub const _SC_SCHAR_MAX: c_int = 111;
pub const _SC_SCHAR_MIN: c_int = 112;
pub const _SC_SHRT_MAX: c_int = 113;
pub const _SC_SHRT_MIN: c_int = 114;
pub const _SC_UCHAR_MAX: c_int = 115;
pub const _SC_UINT_MAX: c_int = 116;
pub const _SC_ULONG_MAX: c_int = 117;
pub const _SC_USHRT_MAX: c_int = 118;
pub const _SC_NL_ARGMAX: c_int = 119;
pub const _SC_NL_LANGMAX: c_int = 120;
pub const _SC_NL_MSGMAX: c_int = 121;
pub const _SC_NL_NMAX: c_int = 122;
pub const _SC_NL_SETMAX: c_int = 123;
pub const _SC_NL_TEXTMAX: c_int = 124;
pub const _SC_XBS5_ILP32_OFF32: c_int = 125;
pub const _SC_XBS5_ILP32_OFFBIG: c_int = 126;
pub const _SC_XBS5_LP64_OFF64: c_int = 127;
pub const _SC_XBS5_LPBIG_OFFBIG: c_int = 128;
pub const _SC_XOPEN_LEGACY: c_int = 129;
pub const _SC_XOPEN_REALTIME: c_int = 130;
pub const _SC_XOPEN_REALTIME_THREADS: c_int = 131;
pub const _SC_ADVISORY_INFO: c_int = 132;
pub const _SC_BARRIERS: c_int = 133;
pub const _SC_BASE: c_int = 134;
pub const _SC_C_LANG_SUPPORT: c_int = 135;
pub const _SC_C_LANG_SUPPORT_R: c_int = 136;
pub const _SC_CLOCK_SELECTION: c_int = 137;
pub const _SC_CPUTIME: c_int = 138;
pub const _SC_THREAD_CPUTIME: c_int = 139;
pub const _SC_DEVICE_IO: c_int = 140;
pub const _SC_DEVICE_SPECIFIC: c_int = 141;
pub const _SC_DEVICE_SPECIFIC_R: c_int = 142;
pub const _SC_FD_MGMT: c_int = 143;
pub const _SC_FIFO: c_int = 144;
pub const _SC_PIPE: c_int = 145;
pub const _SC_FILE_ATTRIBUTES: c_int = 146;
pub const _SC_FILE_LOCKING: c_int = 147;
pub const _SC_FILE_SYSTEM: c_int = 148;
pub const _SC_MONOTONIC_CLOCK: c_int = 149;
pub const _SC_MULTI_PROCESS: c_int = 150;
pub const _SC_SINGLE_PROCESS: c_int = 151;
pub const _SC_NETWORKING: c_int = 152;
pub const _SC_READER_WRITER_LOCKS: c_int = 153;
pub const _SC_SPIN_LOCKS: c_int = 154;
pub const _SC_REGEXP: c_int = 155;
pub const _SC_REGEX_VERSION: c_int = 156;
pub const _SC_SHELL: c_int = 157;
pub const _SC_SIGNALS: c_int = 158;
pub const _SC_SPAWN: c_int = 159;
pub const _SC_SPORADIC_SERVER: c_int = 160;
pub const _SC_THREAD_SPORADIC_SERVER: c_int = 161;
pub const _SC_SYSTEM_DATABASE: c_int = 162;
pub const _SC_SYSTEM_DATABASE_R: c_int = 163;
pub const _SC_TIMEOUTS: c_int = 164;
pub const _SC_TYPED_MEMORY_OBJECTS: c_int = 165;
pub const _SC_USER_GROUPS: c_int = 166;
pub const _SC_USER_GROUPS_R: c_int = 167;
pub const _SC_2_PBS: c_int = 168;
pub const _SC_2_PBS_ACCOUNTING: c_int = 169;
pub const _SC_2_PBS_LOCATE: c_int = 170;
pub const _SC_2_PBS_MESSAGE: c_int = 171;
pub const _SC_2_PBS_TRACK: c_int = 172;
pub const _SC_SYMLOOP_MAX: c_int = 173;
pub const _SC_STREAMS: c_int = 174;
pub const _SC_2_PBS_CHECKPOINT: c_int = 175;
pub const _SC_V6_ILP32_OFF32: c_int = 176;
pub const _SC_V6_ILP32_OFFBIG: c_int = 177;
pub const _SC_V6_LP64_OFF64: c_int = 178;
pub const _SC_V6_LPBIG_OFFBIG: c_int = 179;
pub const _SC_HOST_NAME_MAX: c_int = 180;
pub const _SC_TRACE: c_int = 181;
pub const _SC_TRACE_EVENT_FILTER: c_int = 182;
pub const _SC_TRACE_INHERIT: c_int = 183;
pub const _SC_TRACE_LOG: c_int = 184;
pub const _SC_LEVEL1_ICACHE_SIZE: c_int = 185;
pub const _SC_LEVEL1_ICACHE_ASSOC: c_int = 186;
pub const _SC_LEVEL1_ICACHE_LINESIZE: c_int = 187;
pub const _SC_LEVEL1_DCACHE_SIZE: c_int = 188;
pub const _SC_LEVEL1_DCACHE_ASSOC: c_int = 189;
pub const _SC_LEVEL1_DCACHE_LINESIZE: c_int = 190;
pub const _SC_LEVEL2_CACHE_SIZE: c_int = 191;
pub const _SC_LEVEL2_CACHE_ASSOC: c_int = 192;
pub const _SC_LEVEL2_CACHE_LINESIZE: c_int = 193;
pub const _SC_LEVEL3_CACHE_SIZE: c_int = 194;
pub const _SC_LEVEL3_CACHE_ASSOC: c_int = 195;
pub const _SC_LEVEL3_CACHE_LINESIZE: c_int = 196;
pub const _SC_LEVEL4_CACHE_SIZE: c_int = 197;
pub const _SC_LEVEL4_CACHE_ASSOC: c_int = 198;
pub const _SC_LEVEL4_CACHE_LINESIZE: c_int = 199;
pub const _SC_IPV6: c_int = 235;
pub const _SC_RAW_SOCKETS: c_int = 236;
pub const _SC_V7_ILP32_OFF32: c_int = 237;
pub const _SC_V7_ILP32_OFFBIG: c_int = 238;
pub const _SC_V7_LP64_OFF64: c_int = 239;
pub const _SC_V7_LPBIG_OFFBIG: c_int = 240;
pub const _SC_SS_REPL_MAX: c_int = 241;
pub const _SC_TRACE_EVENT_NAME_MAX: c_int = 242;
pub const _SC_TRACE_NAME_MAX: c_int = 243;
pub const _SC_TRACE_SYS_MAX: c_int = 244;
pub const _SC_TRACE_USER_EVENT_MAX: c_int = 245;
pub const _SC_XOPEN_STREAMS: c_int = 246;
pub const _SC_THREAD_ROBUST_PRIO_INHERIT: c_int = 247;
pub const _SC_THREAD_ROBUST_PRIO_PROTECT: c_int = 248;
pub const _SC_MINSIGSTKSZ: c_int = 249;
pub const _SC_SIGSTKSZ: c_int = 250;
const enum_unnamed_6 = c_uint;
pub const _CS_PATH: c_int = 0;
pub const _CS_V6_WIDTH_RESTRICTED_ENVS: c_int = 1;
pub const _CS_GNU_LIBC_VERSION: c_int = 2;
pub const _CS_GNU_LIBPTHREAD_VERSION: c_int = 3;
pub const _CS_V5_WIDTH_RESTRICTED_ENVS: c_int = 4;
pub const _CS_V7_WIDTH_RESTRICTED_ENVS: c_int = 5;
pub const _CS_LFS_CFLAGS: c_int = 1000;
pub const _CS_LFS_LDFLAGS: c_int = 1001;
pub const _CS_LFS_LIBS: c_int = 1002;
pub const _CS_LFS_LINTFLAGS: c_int = 1003;
pub const _CS_LFS64_CFLAGS: c_int = 1004;
pub const _CS_LFS64_LDFLAGS: c_int = 1005;
pub const _CS_LFS64_LIBS: c_int = 1006;
pub const _CS_LFS64_LINTFLAGS: c_int = 1007;
pub const _CS_XBS5_ILP32_OFF32_CFLAGS: c_int = 1100;
pub const _CS_XBS5_ILP32_OFF32_LDFLAGS: c_int = 1101;
pub const _CS_XBS5_ILP32_OFF32_LIBS: c_int = 1102;
pub const _CS_XBS5_ILP32_OFF32_LINTFLAGS: c_int = 1103;
pub const _CS_XBS5_ILP32_OFFBIG_CFLAGS: c_int = 1104;
pub const _CS_XBS5_ILP32_OFFBIG_LDFLAGS: c_int = 1105;
pub const _CS_XBS5_ILP32_OFFBIG_LIBS: c_int = 1106;
pub const _CS_XBS5_ILP32_OFFBIG_LINTFLAGS: c_int = 1107;
pub const _CS_XBS5_LP64_OFF64_CFLAGS: c_int = 1108;
pub const _CS_XBS5_LP64_OFF64_LDFLAGS: c_int = 1109;
pub const _CS_XBS5_LP64_OFF64_LIBS: c_int = 1110;
pub const _CS_XBS5_LP64_OFF64_LINTFLAGS: c_int = 1111;
pub const _CS_XBS5_LPBIG_OFFBIG_CFLAGS: c_int = 1112;
pub const _CS_XBS5_LPBIG_OFFBIG_LDFLAGS: c_int = 1113;
pub const _CS_XBS5_LPBIG_OFFBIG_LIBS: c_int = 1114;
pub const _CS_XBS5_LPBIG_OFFBIG_LINTFLAGS: c_int = 1115;
pub const _CS_POSIX_V6_ILP32_OFF32_CFLAGS: c_int = 1116;
pub const _CS_POSIX_V6_ILP32_OFF32_LDFLAGS: c_int = 1117;
pub const _CS_POSIX_V6_ILP32_OFF32_LIBS: c_int = 1118;
pub const _CS_POSIX_V6_ILP32_OFF32_LINTFLAGS: c_int = 1119;
pub const _CS_POSIX_V6_ILP32_OFFBIG_CFLAGS: c_int = 1120;
pub const _CS_POSIX_V6_ILP32_OFFBIG_LDFLAGS: c_int = 1121;
pub const _CS_POSIX_V6_ILP32_OFFBIG_LIBS: c_int = 1122;
pub const _CS_POSIX_V6_ILP32_OFFBIG_LINTFLAGS: c_int = 1123;
pub const _CS_POSIX_V6_LP64_OFF64_CFLAGS: c_int = 1124;
pub const _CS_POSIX_V6_LP64_OFF64_LDFLAGS: c_int = 1125;
pub const _CS_POSIX_V6_LP64_OFF64_LIBS: c_int = 1126;
pub const _CS_POSIX_V6_LP64_OFF64_LINTFLAGS: c_int = 1127;
pub const _CS_POSIX_V6_LPBIG_OFFBIG_CFLAGS: c_int = 1128;
pub const _CS_POSIX_V6_LPBIG_OFFBIG_LDFLAGS: c_int = 1129;
pub const _CS_POSIX_V6_LPBIG_OFFBIG_LIBS: c_int = 1130;
pub const _CS_POSIX_V6_LPBIG_OFFBIG_LINTFLAGS: c_int = 1131;
pub const _CS_POSIX_V7_ILP32_OFF32_CFLAGS: c_int = 1132;
pub const _CS_POSIX_V7_ILP32_OFF32_LDFLAGS: c_int = 1133;
pub const _CS_POSIX_V7_ILP32_OFF32_LIBS: c_int = 1134;
pub const _CS_POSIX_V7_ILP32_OFF32_LINTFLAGS: c_int = 1135;
pub const _CS_POSIX_V7_ILP32_OFFBIG_CFLAGS: c_int = 1136;
pub const _CS_POSIX_V7_ILP32_OFFBIG_LDFLAGS: c_int = 1137;
pub const _CS_POSIX_V7_ILP32_OFFBIG_LIBS: c_int = 1138;
pub const _CS_POSIX_V7_ILP32_OFFBIG_LINTFLAGS: c_int = 1139;
pub const _CS_POSIX_V7_LP64_OFF64_CFLAGS: c_int = 1140;
pub const _CS_POSIX_V7_LP64_OFF64_LDFLAGS: c_int = 1141;
pub const _CS_POSIX_V7_LP64_OFF64_LIBS: c_int = 1142;
pub const _CS_POSIX_V7_LP64_OFF64_LINTFLAGS: c_int = 1143;
pub const _CS_POSIX_V7_LPBIG_OFFBIG_CFLAGS: c_int = 1144;
pub const _CS_POSIX_V7_LPBIG_OFFBIG_LDFLAGS: c_int = 1145;
pub const _CS_POSIX_V7_LPBIG_OFFBIG_LIBS: c_int = 1146;
pub const _CS_POSIX_V7_LPBIG_OFFBIG_LINTFLAGS: c_int = 1147;
pub const _CS_V6_ENV: c_int = 1148;
pub const _CS_V7_ENV: c_int = 1149;
const enum_unnamed_7 = c_uint;
pub extern fn pathconf(__path: [*c]const u8, __name: c_int) c_long;
pub extern fn fpathconf(__fd: c_int, __name: c_int) c_long;
pub extern fn sysconf(__name: c_int) c_long;
pub extern fn confstr(__name: c_int, __buf: [*c]u8, __len: usize) usize;
pub extern fn getpid() __pid_t;
pub extern fn getppid() __pid_t;
pub extern fn getpgrp() __pid_t;
pub extern fn __getpgid(__pid: __pid_t) __pid_t;
pub extern fn getpgid(__pid: __pid_t) __pid_t;
pub extern fn setpgid(__pid: __pid_t, __pgid: __pid_t) c_int;
pub extern fn setpgrp() c_int;
pub extern fn setsid() __pid_t;
pub extern fn getsid(__pid: __pid_t) __pid_t;
pub extern fn getuid() __uid_t;
pub extern fn geteuid() __uid_t;
pub extern fn getgid() __gid_t;
pub extern fn getegid() __gid_t;
pub extern fn getgroups(__size: c_int, __list: [*c]__gid_t) c_int;
pub extern fn setuid(__uid: __uid_t) c_int;
pub extern fn setreuid(__ruid: __uid_t, __euid: __uid_t) c_int;
pub extern fn seteuid(__uid: __uid_t) c_int;
pub extern fn setgid(__gid: __gid_t) c_int;
pub extern fn setregid(__rgid: __gid_t, __egid: __gid_t) c_int;
pub extern fn setegid(__gid: __gid_t) c_int;
pub extern fn fork() __pid_t;
pub extern fn vfork() __pid_t;
pub extern fn ttyname(__fd: c_int) [*c]u8;
pub extern fn ttyname_r(__fd: c_int, __buf: [*c]u8, __buflen: usize) c_int;
pub extern fn isatty(__fd: c_int) c_int;
pub extern fn ttyslot() c_int;
pub extern fn link(__from: [*c]const u8, __to: [*c]const u8) c_int;
pub extern fn linkat(__fromfd: c_int, __from: [*c]const u8, __tofd: c_int, __to: [*c]const u8, __flags: c_int) c_int;
pub extern fn symlink(__from: [*c]const u8, __to: [*c]const u8) c_int;
pub extern fn readlink(noalias __path: [*c]const u8, noalias __buf: [*c]u8, __len: usize) isize;
pub extern fn symlinkat(__from: [*c]const u8, __tofd: c_int, __to: [*c]const u8) c_int;
pub extern fn readlinkat(__fd: c_int, noalias __path: [*c]const u8, noalias __buf: [*c]u8, __len: usize) isize;
pub extern fn unlink(__name: [*c]const u8) c_int;
pub extern fn unlinkat(__fd: c_int, __name: [*c]const u8, __flag: c_int) c_int;
pub extern fn rmdir(__path: [*c]const u8) c_int;
pub extern fn tcgetpgrp(__fd: c_int) __pid_t;
pub extern fn tcsetpgrp(__fd: c_int, __pgrp_id: __pid_t) c_int;
pub extern fn getlogin() [*c]u8;
pub extern fn getlogin_r(__name: [*c]u8, __name_len: usize) c_int;
pub extern fn setlogin(__name: [*c]const u8) c_int;
pub extern var optarg: [*c]u8;
pub extern var optind: c_int;
pub extern var opterr: c_int;
pub extern var optopt: c_int;
pub extern fn getopt(___argc: c_int, ___argv: [*c]const [*c]u8, __shortopts: [*c]const u8) c_int;
pub extern fn gethostname(__name: [*c]u8, __len: usize) c_int;
pub extern fn sethostname(__name: [*c]const u8, __len: usize) c_int;
pub extern fn sethostid(__id: c_long) c_int;
pub extern fn getdomainname(__name: [*c]u8, __len: usize) c_int;
pub extern fn setdomainname(__name: [*c]const u8, __len: usize) c_int;
pub extern fn vhangup() c_int;
pub extern fn revoke(__file: [*c]const u8) c_int;
pub extern fn profil(__sample_buffer: [*c]c_ushort, __size: usize, __offset: usize, __scale: c_uint) c_int;
pub extern fn acct(__name: [*c]const u8) c_int;
pub extern fn getusershell() [*c]u8;
pub extern fn endusershell() void;
pub extern fn setusershell() void;
pub extern fn daemon(__nochdir: c_int, __noclose: c_int) c_int;
pub extern fn chroot(__path: [*c]const u8) c_int;
pub extern fn getpass(__prompt: [*c]const u8) [*c]u8;
pub extern fn fsync(__fd: c_int) c_int;
pub extern fn gethostid() c_long;
pub extern fn sync() void;
pub extern fn getpagesize() c_int;
pub extern fn getdtablesize() c_int;
pub extern fn truncate(__file: [*c]const u8, __length: __off_t) c_int;
pub extern fn ftruncate(__fd: c_int, __length: __off_t) c_int;
pub extern fn brk(__addr: ?*anyopaque) c_int;
pub extern fn sbrk(__delta: isize) ?*anyopaque;
pub extern fn syscall(__sysno: c_long, ...) c_long;
pub extern fn lockf(__fd: c_int, __cmd: c_int, __len: __off_t) c_int;
pub extern fn fdatasync(__fildes: c_int) c_int;
pub extern fn crypt(__key: [*c]const u8, __salt: [*c]const u8) [*c]u8;
pub extern fn getentropy(__buffer: ?*anyopaque, __length: usize) c_int;
pub const la_int64_t = i64;
pub const la_uint64_t = u64;
pub const la_ssize_t = isize;
pub extern fn archive_version_number() c_int;
pub extern fn archive_version_string() [*c]const u8;
pub extern fn archive_version_details() [*c]const u8;
pub extern fn archive_zlib_version() [*c]const u8;
pub extern fn archive_liblzma_version() [*c]const u8;
pub extern fn archive_bzlib_version() [*c]const u8;
pub extern fn archive_liblz4_version() [*c]const u8;
pub extern fn archive_libzstd_version() [*c]const u8;
pub extern fn archive_liblzo2_version() [*c]const u8;
pub extern fn archive_libexpat_version() [*c]const u8;
pub extern fn archive_libbsdxml_version() [*c]const u8;
pub extern fn archive_libxml2_version() [*c]const u8;
pub extern fn archive_mbedtls_version() [*c]const u8;
pub extern fn archive_nettle_version() [*c]const u8;
pub extern fn archive_openssl_version() [*c]const u8;
pub extern fn archive_libmd_version() [*c]const u8;
pub extern fn archive_commoncrypto_version() [*c]const u8;
pub extern fn archive_cng_version() [*c]const u8;
pub extern fn archive_wincrypt_version() [*c]const u8;
pub extern fn archive_librichacl_version() [*c]const u8;
pub extern fn archive_libacl_version() [*c]const u8;
pub extern fn archive_libattr_version() [*c]const u8;
pub extern fn archive_libiconv_version() [*c]const u8;
pub extern fn archive_libpcre_version() [*c]const u8;
pub extern fn archive_libpcre2_version() [*c]const u8;
pub const struct_archive = opaque {
    pub const archive_read_support_compression_all = __root.archive_read_support_compression_all;
    pub const archive_read_support_compression_bzip2 = __root.archive_read_support_compression_bzip2;
    pub const archive_read_support_compression_compress = __root.archive_read_support_compression_compress;
    pub const archive_read_support_compression_gzip = __root.archive_read_support_compression_gzip;
    pub const archive_read_support_compression_lzip = __root.archive_read_support_compression_lzip;
    pub const archive_read_support_compression_lzma = __root.archive_read_support_compression_lzma;
    pub const archive_read_support_compression_none = __root.archive_read_support_compression_none;
    pub const archive_read_support_compression_program = __root.archive_read_support_compression_program;
    pub const archive_read_support_compression_program_signature = __root.archive_read_support_compression_program_signature;
    pub const archive_read_support_compression_rpm = __root.archive_read_support_compression_rpm;
    pub const archive_read_support_compression_uu = __root.archive_read_support_compression_uu;
    pub const archive_read_support_compression_xz = __root.archive_read_support_compression_xz;
    pub const archive_read_support_filter_all = __root.archive_read_support_filter_all;
    pub const archive_read_support_filter_by_code = __root.archive_read_support_filter_by_code;
    pub const archive_read_support_filter_bzip2 = __root.archive_read_support_filter_bzip2;
    pub const archive_read_support_filter_compress = __root.archive_read_support_filter_compress;
    pub const archive_read_support_filter_gzip = __root.archive_read_support_filter_gzip;
    pub const archive_read_support_filter_grzip = __root.archive_read_support_filter_grzip;
    pub const archive_read_support_filter_lrzip = __root.archive_read_support_filter_lrzip;
    pub const archive_read_support_filter_lz4 = __root.archive_read_support_filter_lz4;
    pub const archive_read_support_filter_lzip = __root.archive_read_support_filter_lzip;
    pub const archive_read_support_filter_lzma = __root.archive_read_support_filter_lzma;
    pub const archive_read_support_filter_lzop = __root.archive_read_support_filter_lzop;
    pub const archive_read_support_filter_none = __root.archive_read_support_filter_none;
    pub const archive_read_support_filter_program = __root.archive_read_support_filter_program;
    pub const archive_read_support_filter_program_signature = __root.archive_read_support_filter_program_signature;
    pub const archive_read_support_filter_rpm = __root.archive_read_support_filter_rpm;
    pub const archive_read_support_filter_uu = __root.archive_read_support_filter_uu;
    pub const archive_read_support_filter_xz = __root.archive_read_support_filter_xz;
    pub const archive_read_support_filter_zstd = __root.archive_read_support_filter_zstd;
    pub const archive_read_support_format_7zip = __root.archive_read_support_format_7zip;
    pub const archive_read_support_format_all = __root.archive_read_support_format_all;
    pub const archive_read_support_format_ar = __root.archive_read_support_format_ar;
    pub const archive_read_support_format_by_code = __root.archive_read_support_format_by_code;
    pub const archive_read_support_format_cab = __root.archive_read_support_format_cab;
    pub const archive_read_support_format_cpio = __root.archive_read_support_format_cpio;
    pub const archive_read_support_format_empty = __root.archive_read_support_format_empty;
    pub const archive_read_support_format_gnutar = __root.archive_read_support_format_gnutar;
    pub const archive_read_support_format_iso9660 = __root.archive_read_support_format_iso9660;
    pub const archive_read_support_format_lha = __root.archive_read_support_format_lha;
    pub const archive_read_support_format_mtree = __root.archive_read_support_format_mtree;
    pub const archive_read_support_format_rar = __root.archive_read_support_format_rar;
    pub const archive_read_support_format_rar5 = __root.archive_read_support_format_rar5;
    pub const archive_read_support_format_raw = __root.archive_read_support_format_raw;
    pub const archive_read_support_format_tar = __root.archive_read_support_format_tar;
    pub const archive_read_support_format_warc = __root.archive_read_support_format_warc;
    pub const archive_read_support_format_xar = __root.archive_read_support_format_xar;
    pub const archive_read_support_format_zip = __root.archive_read_support_format_zip;
    pub const archive_read_support_format_zip_streamable = __root.archive_read_support_format_zip_streamable;
    pub const archive_read_support_format_zip_seekable = __root.archive_read_support_format_zip_seekable;
    pub const archive_read_set_format = __root.archive_read_set_format;
    pub const archive_read_append_filter = __root.archive_read_append_filter;
    pub const archive_read_append_filter_program = __root.archive_read_append_filter_program;
    pub const archive_read_append_filter_program_signature = __root.archive_read_append_filter_program_signature;
    pub const archive_read_set_open_callback = __root.archive_read_set_open_callback;
    pub const archive_read_set_read_callback = __root.archive_read_set_read_callback;
    pub const archive_read_set_seek_callback = __root.archive_read_set_seek_callback;
    pub const archive_read_set_skip_callback = __root.archive_read_set_skip_callback;
    pub const archive_read_set_close_callback = __root.archive_read_set_close_callback;
    pub const archive_read_set_switch_callback = __root.archive_read_set_switch_callback;
    pub const archive_read_set_callback_data = __root.archive_read_set_callback_data;
    pub const archive_read_set_callback_data2 = __root.archive_read_set_callback_data2;
    pub const archive_read_add_callback_data = __root.archive_read_add_callback_data;
    pub const archive_read_append_callback_data = __root.archive_read_append_callback_data;
    pub const archive_read_prepend_callback_data = __root.archive_read_prepend_callback_data;
    pub const archive_read_open1 = __root.archive_read_open1;
    pub const archive_read_open = __root.archive_read_open;
    pub const archive_read_open2 = __root.archive_read_open2;
    pub const archive_read_open_filename = __root.archive_read_open_filename;
    pub const archive_read_open_filenames = __root.archive_read_open_filenames;
    pub const archive_read_open_filename_w = __root.archive_read_open_filename_w;
    pub const archive_read_open_file = __root.archive_read_open_file;
    pub const archive_read_open_memory = __root.archive_read_open_memory;
    pub const archive_read_open_memory2 = __root.archive_read_open_memory2;
    pub const archive_read_open_fd = __root.archive_read_open_fd;
    pub const archive_read_open_FILE = __root.archive_read_open_FILE;
    pub const archive_read_next_header = __root.archive_read_next_header;
    pub const archive_read_next_header2 = __root.archive_read_next_header2;
    pub const archive_read_header_position = __root.archive_read_header_position;
    pub const archive_read_has_encrypted_entries = __root.archive_read_has_encrypted_entries;
    pub const archive_read_format_capabilities = __root.archive_read_format_capabilities;
    pub const archive_read_data = __root.archive_read_data;
    pub const archive_seek_data = __root.archive_seek_data;
    pub const archive_read_data_block = __root.archive_read_data_block;
    pub const archive_read_data_skip = __root.archive_read_data_skip;
    pub const archive_read_data_into_fd = __root.archive_read_data_into_fd;
    pub const archive_read_set_format_option = __root.archive_read_set_format_option;
    pub const archive_read_set_filter_option = __root.archive_read_set_filter_option;
    pub const archive_read_set_option = __root.archive_read_set_option;
    pub const archive_read_set_options = __root.archive_read_set_options;
    pub const archive_read_add_passphrase = __root.archive_read_add_passphrase;
    pub const archive_read_set_passphrase_callback = __root.archive_read_set_passphrase_callback;
    pub const archive_read_extract = __root.archive_read_extract;
    pub const archive_read_extract2 = __root.archive_read_extract2;
    pub const archive_read_extract_set_progress_callback = __root.archive_read_extract_set_progress_callback;
    pub const archive_read_extract_set_skip_file = __root.archive_read_extract_set_skip_file;
    pub const archive_read_close = __root.archive_read_close;
    pub const archive_read_free = __root.archive_read_free;
    pub const archive_read_finish = __root.archive_read_finish;
    pub const archive_write_set_bytes_per_block = __root.archive_write_set_bytes_per_block;
    pub const archive_write_get_bytes_per_block = __root.archive_write_get_bytes_per_block;
    pub const archive_write_set_bytes_in_last_block = __root.archive_write_set_bytes_in_last_block;
    pub const archive_write_get_bytes_in_last_block = __root.archive_write_get_bytes_in_last_block;
    pub const archive_write_set_skip_file = __root.archive_write_set_skip_file;
    pub const archive_write_set_compression_bzip2 = __root.archive_write_set_compression_bzip2;
    pub const archive_write_set_compression_compress = __root.archive_write_set_compression_compress;
    pub const archive_write_set_compression_gzip = __root.archive_write_set_compression_gzip;
    pub const archive_write_set_compression_lzip = __root.archive_write_set_compression_lzip;
    pub const archive_write_set_compression_lzma = __root.archive_write_set_compression_lzma;
    pub const archive_write_set_compression_none = __root.archive_write_set_compression_none;
    pub const archive_write_set_compression_program = __root.archive_write_set_compression_program;
    pub const archive_write_set_compression_xz = __root.archive_write_set_compression_xz;
    pub const archive_write_add_filter = __root.archive_write_add_filter;
    pub const archive_write_add_filter_by_name = __root.archive_write_add_filter_by_name;
    pub const archive_write_add_filter_b64encode = __root.archive_write_add_filter_b64encode;
    pub const archive_write_add_filter_bzip2 = __root.archive_write_add_filter_bzip2;
    pub const archive_write_add_filter_compress = __root.archive_write_add_filter_compress;
    pub const archive_write_add_filter_grzip = __root.archive_write_add_filter_grzip;
    pub const archive_write_add_filter_gzip = __root.archive_write_add_filter_gzip;
    pub const archive_write_add_filter_lrzip = __root.archive_write_add_filter_lrzip;
    pub const archive_write_add_filter_lz4 = __root.archive_write_add_filter_lz4;
    pub const archive_write_add_filter_lzip = __root.archive_write_add_filter_lzip;
    pub const archive_write_add_filter_lzma = __root.archive_write_add_filter_lzma;
    pub const archive_write_add_filter_lzop = __root.archive_write_add_filter_lzop;
    pub const archive_write_add_filter_none = __root.archive_write_add_filter_none;
    pub const archive_write_add_filter_program = __root.archive_write_add_filter_program;
    pub const archive_write_add_filter_uuencode = __root.archive_write_add_filter_uuencode;
    pub const archive_write_add_filter_xz = __root.archive_write_add_filter_xz;
    pub const archive_write_add_filter_zstd = __root.archive_write_add_filter_zstd;
    pub const archive_write_set_format = __root.archive_write_set_format;
    pub const archive_write_set_format_by_name = __root.archive_write_set_format_by_name;
    pub const archive_write_set_format_7zip = __root.archive_write_set_format_7zip;
    pub const archive_write_set_format_ar_bsd = __root.archive_write_set_format_ar_bsd;
    pub const archive_write_set_format_ar_svr4 = __root.archive_write_set_format_ar_svr4;
    pub const archive_write_set_format_cpio = __root.archive_write_set_format_cpio;
    pub const archive_write_set_format_cpio_bin = __root.archive_write_set_format_cpio_bin;
    pub const archive_write_set_format_cpio_newc = __root.archive_write_set_format_cpio_newc;
    pub const archive_write_set_format_cpio_odc = __root.archive_write_set_format_cpio_odc;
    pub const archive_write_set_format_cpio_pwb = __root.archive_write_set_format_cpio_pwb;
    pub const archive_write_set_format_gnutar = __root.archive_write_set_format_gnutar;
    pub const archive_write_set_format_iso9660 = __root.archive_write_set_format_iso9660;
    pub const archive_write_set_format_mtree = __root.archive_write_set_format_mtree;
    pub const archive_write_set_format_mtree_classic = __root.archive_write_set_format_mtree_classic;
    pub const archive_write_set_format_pax = __root.archive_write_set_format_pax;
    pub const archive_write_set_format_pax_restricted = __root.archive_write_set_format_pax_restricted;
    pub const archive_write_set_format_raw = __root.archive_write_set_format_raw;
    pub const archive_write_set_format_shar = __root.archive_write_set_format_shar;
    pub const archive_write_set_format_shar_dump = __root.archive_write_set_format_shar_dump;
    pub const archive_write_set_format_ustar = __root.archive_write_set_format_ustar;
    pub const archive_write_set_format_v7tar = __root.archive_write_set_format_v7tar;
    pub const archive_write_set_format_warc = __root.archive_write_set_format_warc;
    pub const archive_write_set_format_xar = __root.archive_write_set_format_xar;
    pub const archive_write_set_format_zip = __root.archive_write_set_format_zip;
    pub const archive_write_set_format_filter_by_ext = __root.archive_write_set_format_filter_by_ext;
    pub const archive_write_set_format_filter_by_ext_def = __root.archive_write_set_format_filter_by_ext_def;
    pub const archive_write_zip_set_compression_deflate = __root.archive_write_zip_set_compression_deflate;
    pub const archive_write_zip_set_compression_store = __root.archive_write_zip_set_compression_store;
    pub const archive_write_zip_set_compression_lzma = __root.archive_write_zip_set_compression_lzma;
    pub const archive_write_zip_set_compression_xz = __root.archive_write_zip_set_compression_xz;
    pub const archive_write_zip_set_compression_bzip2 = __root.archive_write_zip_set_compression_bzip2;
    pub const archive_write_zip_set_compression_zstd = __root.archive_write_zip_set_compression_zstd;
    pub const archive_write_open = __root.archive_write_open;
    pub const archive_write_open2 = __root.archive_write_open2;
    pub const archive_write_open_fd = __root.archive_write_open_fd;
    pub const archive_write_open_filename = __root.archive_write_open_filename;
    pub const archive_write_open_filename_w = __root.archive_write_open_filename_w;
    pub const archive_write_open_file = __root.archive_write_open_file;
    pub const archive_write_open_FILE = __root.archive_write_open_FILE;
    pub const archive_write_open_memory = __root.archive_write_open_memory;
    pub const archive_write_header = __root.archive_write_header;
    pub const archive_write_data = __root.archive_write_data;
    pub const archive_write_data_block = __root.archive_write_data_block;
    pub const archive_write_finish_entry = __root.archive_write_finish_entry;
    pub const archive_write_close = __root.archive_write_close;
    pub const archive_write_fail = __root.archive_write_fail;
    pub const archive_write_free = __root.archive_write_free;
    pub const archive_write_finish = __root.archive_write_finish;
    pub const archive_write_set_format_option = __root.archive_write_set_format_option;
    pub const archive_write_set_filter_option = __root.archive_write_set_filter_option;
    pub const archive_write_set_option = __root.archive_write_set_option;
    pub const archive_write_set_options = __root.archive_write_set_options;
    pub const archive_write_set_passphrase = __root.archive_write_set_passphrase;
    pub const archive_write_set_passphrase_callback = __root.archive_write_set_passphrase_callback;
    pub const archive_write_disk_set_skip_file = __root.archive_write_disk_set_skip_file;
    pub const archive_write_disk_set_options = __root.archive_write_disk_set_options;
    pub const archive_write_disk_set_standard_lookup = __root.archive_write_disk_set_standard_lookup;
    pub const archive_write_disk_set_group_lookup = __root.archive_write_disk_set_group_lookup;
    pub const archive_write_disk_set_user_lookup = __root.archive_write_disk_set_user_lookup;
    pub const archive_write_disk_gid = __root.archive_write_disk_gid;
    pub const archive_write_disk_uid = __root.archive_write_disk_uid;
    pub const archive_read_disk_set_symlink_logical = __root.archive_read_disk_set_symlink_logical;
    pub const archive_read_disk_set_symlink_physical = __root.archive_read_disk_set_symlink_physical;
    pub const archive_read_disk_set_symlink_hybrid = __root.archive_read_disk_set_symlink_hybrid;
    pub const archive_read_disk_entry_from_file = __root.archive_read_disk_entry_from_file;
    pub const archive_read_disk_gname = __root.archive_read_disk_gname;
    pub const archive_read_disk_uname = __root.archive_read_disk_uname;
    pub const archive_read_disk_set_standard_lookup = __root.archive_read_disk_set_standard_lookup;
    pub const archive_read_disk_set_gname_lookup = __root.archive_read_disk_set_gname_lookup;
    pub const archive_read_disk_set_uname_lookup = __root.archive_read_disk_set_uname_lookup;
    pub const archive_read_disk_open = __root.archive_read_disk_open;
    pub const archive_read_disk_open_w = __root.archive_read_disk_open_w;
    pub const archive_read_disk_descend = __root.archive_read_disk_descend;
    pub const archive_read_disk_can_descend = __root.archive_read_disk_can_descend;
    pub const archive_read_disk_current_filesystem = __root.archive_read_disk_current_filesystem;
    pub const archive_read_disk_current_filesystem_is_synthetic = __root.archive_read_disk_current_filesystem_is_synthetic;
    pub const archive_read_disk_current_filesystem_is_remote = __root.archive_read_disk_current_filesystem_is_remote;
    pub const archive_read_disk_set_atime_restored = __root.archive_read_disk_set_atime_restored;
    pub const archive_read_disk_set_behavior = __root.archive_read_disk_set_behavior;
    pub const archive_read_disk_set_matching = __root.archive_read_disk_set_matching;
    pub const archive_read_disk_set_metadata_filter_callback = __root.archive_read_disk_set_metadata_filter_callback;
    pub const archive_free = __root.archive_free;
    pub const archive_filter_count = __root.archive_filter_count;
    pub const archive_filter_bytes = __root.archive_filter_bytes;
    pub const archive_filter_code = __root.archive_filter_code;
    pub const archive_filter_name = __root.archive_filter_name;
    pub const archive_position_compressed = __root.archive_position_compressed;
    pub const archive_position_uncompressed = __root.archive_position_uncompressed;
    pub const archive_compression_name = __root.archive_compression_name;
    pub const archive_compression = __root.archive_compression;
    pub const archive_errno = __root.archive_errno;
    pub const archive_error_string = __root.archive_error_string;
    pub const archive_format_name = __root.archive_format_name;
    pub const archive_format = __root.archive_format;
    pub const archive_clear_error = __root.archive_clear_error;
    pub const archive_set_error = __root.archive_set_error;
    pub const archive_copy_error = __root.archive_copy_error;
    pub const archive_file_count = __root.archive_file_count;
    pub const archive_match_free = __root.archive_match_free;
    pub const archive_match_excluded = __root.archive_match_excluded;
    pub const archive_match_path_excluded = __root.archive_match_path_excluded;
    pub const archive_match_set_inclusion_recursion = __root.archive_match_set_inclusion_recursion;
    pub const archive_match_exclude_pattern = __root.archive_match_exclude_pattern;
    pub const archive_match_exclude_pattern_w = __root.archive_match_exclude_pattern_w;
    pub const archive_match_exclude_pattern_from_file = __root.archive_match_exclude_pattern_from_file;
    pub const archive_match_exclude_pattern_from_file_w = __root.archive_match_exclude_pattern_from_file_w;
    pub const archive_match_include_pattern = __root.archive_match_include_pattern;
    pub const archive_match_include_pattern_w = __root.archive_match_include_pattern_w;
    pub const archive_match_include_pattern_from_file = __root.archive_match_include_pattern_from_file;
    pub const archive_match_include_pattern_from_file_w = __root.archive_match_include_pattern_from_file_w;
    pub const archive_match_path_unmatched_inclusions = __root.archive_match_path_unmatched_inclusions;
    pub const archive_match_path_unmatched_inclusions_next = __root.archive_match_path_unmatched_inclusions_next;
    pub const archive_match_path_unmatched_inclusions_next_w = __root.archive_match_path_unmatched_inclusions_next_w;
    pub const archive_match_time_excluded = __root.archive_match_time_excluded;
    pub const archive_match_include_time = __root.archive_match_include_time;
    pub const archive_match_include_date = __root.archive_match_include_date;
    pub const archive_match_include_date_w = __root.archive_match_include_date_w;
    pub const archive_match_include_file_time = __root.archive_match_include_file_time;
    pub const archive_match_include_file_time_w = __root.archive_match_include_file_time_w;
    pub const archive_match_exclude_entry = __root.archive_match_exclude_entry;
    pub const archive_match_owner_excluded = __root.archive_match_owner_excluded;
    pub const archive_match_include_uid = __root.archive_match_include_uid;
    pub const archive_match_include_gid = __root.archive_match_include_gid;
    pub const archive_match_include_uname = __root.archive_match_include_uname;
    pub const archive_match_include_uname_w = __root.archive_match_include_uname_w;
    pub const archive_match_include_gname = __root.archive_match_include_gname;
    pub const archive_match_include_gname_w = __root.archive_match_include_gname_w;
    pub const archive_entry_new2 = __root.archive_entry_new2;
    pub const read_support_compression_all = __root.archive_read_support_compression_all;
    pub const read_support_compression_bzip2 = __root.archive_read_support_compression_bzip2;
    pub const read_support_compression_compress = __root.archive_read_support_compression_compress;
    pub const read_support_compression_gzip = __root.archive_read_support_compression_gzip;
    pub const read_support_compression_lzip = __root.archive_read_support_compression_lzip;
    pub const read_support_compression_lzma = __root.archive_read_support_compression_lzma;
    pub const read_support_compression_none = __root.archive_read_support_compression_none;
    pub const read_support_compression_program = __root.archive_read_support_compression_program;
    pub const read_support_compression_program_signature = __root.archive_read_support_compression_program_signature;
    pub const read_support_compression_rpm = __root.archive_read_support_compression_rpm;
    pub const read_support_compression_uu = __root.archive_read_support_compression_uu;
    pub const read_support_compression_xz = __root.archive_read_support_compression_xz;
    pub const read_support_filter_all = __root.archive_read_support_filter_all;
    pub const read_support_filter_by_code = __root.archive_read_support_filter_by_code;
    pub const read_support_filter_bzip2 = __root.archive_read_support_filter_bzip2;
    pub const read_support_filter_compress = __root.archive_read_support_filter_compress;
    pub const read_support_filter_gzip = __root.archive_read_support_filter_gzip;
    pub const read_support_filter_grzip = __root.archive_read_support_filter_grzip;
    pub const read_support_filter_lrzip = __root.archive_read_support_filter_lrzip;
    pub const read_support_filter_lz4 = __root.archive_read_support_filter_lz4;
    pub const read_support_filter_lzip = __root.archive_read_support_filter_lzip;
    pub const read_support_filter_lzma = __root.archive_read_support_filter_lzma;
    pub const read_support_filter_lzop = __root.archive_read_support_filter_lzop;
    pub const read_support_filter_none = __root.archive_read_support_filter_none;
    pub const read_support_filter_program = __root.archive_read_support_filter_program;
    pub const read_support_filter_program_signature = __root.archive_read_support_filter_program_signature;
    pub const read_support_filter_rpm = __root.archive_read_support_filter_rpm;
    pub const read_support_filter_uu = __root.archive_read_support_filter_uu;
    pub const read_support_filter_xz = __root.archive_read_support_filter_xz;
    pub const read_support_filter_zstd = __root.archive_read_support_filter_zstd;
    pub const read_support_format_7zip = __root.archive_read_support_format_7zip;
    pub const read_support_format_all = __root.archive_read_support_format_all;
    pub const read_support_format_ar = __root.archive_read_support_format_ar;
    pub const read_support_format_by_code = __root.archive_read_support_format_by_code;
    pub const read_support_format_cab = __root.archive_read_support_format_cab;
    pub const read_support_format_cpio = __root.archive_read_support_format_cpio;
    pub const read_support_format_empty = __root.archive_read_support_format_empty;
    pub const read_support_format_gnutar = __root.archive_read_support_format_gnutar;
    pub const read_support_format_iso9660 = __root.archive_read_support_format_iso9660;
    pub const read_support_format_lha = __root.archive_read_support_format_lha;
    pub const read_support_format_mtree = __root.archive_read_support_format_mtree;
    pub const read_support_format_rar = __root.archive_read_support_format_rar;
    pub const read_support_format_rar5 = __root.archive_read_support_format_rar5;
    pub const read_support_format_raw = __root.archive_read_support_format_raw;
    pub const read_support_format_tar = __root.archive_read_support_format_tar;
    pub const read_support_format_warc = __root.archive_read_support_format_warc;
    pub const read_support_format_xar = __root.archive_read_support_format_xar;
    pub const read_support_format_zip = __root.archive_read_support_format_zip;
    pub const read_support_format_zip_streamable = __root.archive_read_support_format_zip_streamable;
    pub const read_support_format_zip_seekable = __root.archive_read_support_format_zip_seekable;
    pub const read_set_format = __root.archive_read_set_format;
    pub const read_append_filter = __root.archive_read_append_filter;
    pub const read_append_filter_program = __root.archive_read_append_filter_program;
    pub const read_append_filter_program_signature = __root.archive_read_append_filter_program_signature;
    pub const read_set_open_callback = __root.archive_read_set_open_callback;
    pub const read_set_read_callback = __root.archive_read_set_read_callback;
    pub const read_set_seek_callback = __root.archive_read_set_seek_callback;
    pub const read_set_skip_callback = __root.archive_read_set_skip_callback;
    pub const read_set_close_callback = __root.archive_read_set_close_callback;
    pub const read_set_switch_callback = __root.archive_read_set_switch_callback;
    pub const read_set_callback_data = __root.archive_read_set_callback_data;
    pub const read_set_callback_data2 = __root.archive_read_set_callback_data2;
    pub const read_add_callback_data = __root.archive_read_add_callback_data;
    pub const read_append_callback_data = __root.archive_read_append_callback_data;
    pub const read_prepend_callback_data = __root.archive_read_prepend_callback_data;
    pub const read_open1 = __root.archive_read_open1;
    pub const read_open = __root.archive_read_open;
    pub const read_open2 = __root.archive_read_open2;
    pub const read_open_filename = __root.archive_read_open_filename;
    pub const read_open_filenames = __root.archive_read_open_filenames;
    pub const read_open_filename_w = __root.archive_read_open_filename_w;
    pub const read_open_file = __root.archive_read_open_file;
    pub const read_open_memory = __root.archive_read_open_memory;
    pub const read_open_memory2 = __root.archive_read_open_memory2;
    pub const read_open_fd = __root.archive_read_open_fd;
    pub const read_open_FILE = __root.archive_read_open_FILE;
    pub const read_next_header = __root.archive_read_next_header;
    pub const read_next_header2 = __root.archive_read_next_header2;
    pub const read_header_position = __root.archive_read_header_position;
    pub const read_has_encrypted_entries = __root.archive_read_has_encrypted_entries;
    pub const read_format_capabilities = __root.archive_read_format_capabilities;
    pub const read_data = __root.archive_read_data;
    pub const seek_data = __root.archive_seek_data;
    pub const read_data_block = __root.archive_read_data_block;
    pub const read_data_skip = __root.archive_read_data_skip;
    pub const read_data_into_fd = __root.archive_read_data_into_fd;
    pub const read_set_format_option = __root.archive_read_set_format_option;
    pub const read_set_filter_option = __root.archive_read_set_filter_option;
    pub const read_set_option = __root.archive_read_set_option;
    pub const read_set_options = __root.archive_read_set_options;
    pub const read_add_passphrase = __root.archive_read_add_passphrase;
    pub const read_set_passphrase_callback = __root.archive_read_set_passphrase_callback;
    pub const read_extract = __root.archive_read_extract;
    pub const read_extract2 = __root.archive_read_extract2;
    pub const read_extract_set_progress_callback = __root.archive_read_extract_set_progress_callback;
    pub const read_extract_set_skip_file = __root.archive_read_extract_set_skip_file;
    pub const read_close = __root.archive_read_close;
    pub const read_free = __root.archive_read_free;
    pub const read_finish = __root.archive_read_finish;
    pub const write_set_bytes_per_block = __root.archive_write_set_bytes_per_block;
    pub const write_get_bytes_per_block = __root.archive_write_get_bytes_per_block;
    pub const write_set_bytes_in_last_block = __root.archive_write_set_bytes_in_last_block;
    pub const write_get_bytes_in_last_block = __root.archive_write_get_bytes_in_last_block;
    pub const write_set_skip_file = __root.archive_write_set_skip_file;
    pub const write_set_compression_bzip2 = __root.archive_write_set_compression_bzip2;
    pub const write_set_compression_compress = __root.archive_write_set_compression_compress;
    pub const write_set_compression_gzip = __root.archive_write_set_compression_gzip;
    pub const write_set_compression_lzip = __root.archive_write_set_compression_lzip;
    pub const write_set_compression_lzma = __root.archive_write_set_compression_lzma;
    pub const write_set_compression_none = __root.archive_write_set_compression_none;
    pub const write_set_compression_program = __root.archive_write_set_compression_program;
    pub const write_set_compression_xz = __root.archive_write_set_compression_xz;
    pub const write_add_filter = __root.archive_write_add_filter;
    pub const write_add_filter_by_name = __root.archive_write_add_filter_by_name;
    pub const write_add_filter_b64encode = __root.archive_write_add_filter_b64encode;
    pub const write_add_filter_bzip2 = __root.archive_write_add_filter_bzip2;
    pub const write_add_filter_compress = __root.archive_write_add_filter_compress;
    pub const write_add_filter_grzip = __root.archive_write_add_filter_grzip;
    pub const write_add_filter_gzip = __root.archive_write_add_filter_gzip;
    pub const write_add_filter_lrzip = __root.archive_write_add_filter_lrzip;
    pub const write_add_filter_lz4 = __root.archive_write_add_filter_lz4;
    pub const write_add_filter_lzip = __root.archive_write_add_filter_lzip;
    pub const write_add_filter_lzma = __root.archive_write_add_filter_lzma;
    pub const write_add_filter_lzop = __root.archive_write_add_filter_lzop;
    pub const write_add_filter_none = __root.archive_write_add_filter_none;
    pub const write_add_filter_program = __root.archive_write_add_filter_program;
    pub const write_add_filter_uuencode = __root.archive_write_add_filter_uuencode;
    pub const write_add_filter_xz = __root.archive_write_add_filter_xz;
    pub const write_add_filter_zstd = __root.archive_write_add_filter_zstd;
    pub const write_set_format = __root.archive_write_set_format;
    pub const write_set_format_by_name = __root.archive_write_set_format_by_name;
    pub const write_set_format_7zip = __root.archive_write_set_format_7zip;
    pub const write_set_format_ar_bsd = __root.archive_write_set_format_ar_bsd;
    pub const write_set_format_ar_svr4 = __root.archive_write_set_format_ar_svr4;
    pub const write_set_format_cpio = __root.archive_write_set_format_cpio;
    pub const write_set_format_cpio_bin = __root.archive_write_set_format_cpio_bin;
    pub const write_set_format_cpio_newc = __root.archive_write_set_format_cpio_newc;
    pub const write_set_format_cpio_odc = __root.archive_write_set_format_cpio_odc;
    pub const write_set_format_cpio_pwb = __root.archive_write_set_format_cpio_pwb;
    pub const write_set_format_gnutar = __root.archive_write_set_format_gnutar;
    pub const write_set_format_iso9660 = __root.archive_write_set_format_iso9660;
    pub const write_set_format_mtree = __root.archive_write_set_format_mtree;
    pub const write_set_format_mtree_classic = __root.archive_write_set_format_mtree_classic;
    pub const write_set_format_pax = __root.archive_write_set_format_pax;
    pub const write_set_format_pax_restricted = __root.archive_write_set_format_pax_restricted;
    pub const write_set_format_raw = __root.archive_write_set_format_raw;
    pub const write_set_format_shar = __root.archive_write_set_format_shar;
    pub const write_set_format_shar_dump = __root.archive_write_set_format_shar_dump;
    pub const write_set_format_ustar = __root.archive_write_set_format_ustar;
    pub const write_set_format_v7tar = __root.archive_write_set_format_v7tar;
    pub const write_set_format_warc = __root.archive_write_set_format_warc;
    pub const write_set_format_xar = __root.archive_write_set_format_xar;
    pub const write_set_format_zip = __root.archive_write_set_format_zip;
    pub const write_set_format_filter_by_ext = __root.archive_write_set_format_filter_by_ext;
    pub const write_set_format_filter_by_ext_def = __root.archive_write_set_format_filter_by_ext_def;
    pub const write_zip_set_compression_deflate = __root.archive_write_zip_set_compression_deflate;
    pub const write_zip_set_compression_store = __root.archive_write_zip_set_compression_store;
    pub const write_zip_set_compression_lzma = __root.archive_write_zip_set_compression_lzma;
    pub const write_zip_set_compression_xz = __root.archive_write_zip_set_compression_xz;
    pub const write_zip_set_compression_bzip2 = __root.archive_write_zip_set_compression_bzip2;
    pub const write_zip_set_compression_zstd = __root.archive_write_zip_set_compression_zstd;
    pub const write_open = __root.archive_write_open;
    pub const write_open2 = __root.archive_write_open2;
    pub const write_open_fd = __root.archive_write_open_fd;
    pub const write_open_filename = __root.archive_write_open_filename;
    pub const write_open_filename_w = __root.archive_write_open_filename_w;
    pub const write_open_file = __root.archive_write_open_file;
    pub const write_open_FILE = __root.archive_write_open_FILE;
    pub const write_open_memory = __root.archive_write_open_memory;
    pub const write_header = __root.archive_write_header;
    pub const write_data = __root.archive_write_data;
    pub const write_data_block = __root.archive_write_data_block;
    pub const write_finish_entry = __root.archive_write_finish_entry;
    pub const write_close = __root.archive_write_close;
    pub const write_fail = __root.archive_write_fail;
    pub const write_free = __root.archive_write_free;
    pub const write_finish = __root.archive_write_finish;
    pub const write_set_format_option = __root.archive_write_set_format_option;
    pub const write_set_filter_option = __root.archive_write_set_filter_option;
    pub const write_set_option = __root.archive_write_set_option;
    pub const write_set_options = __root.archive_write_set_options;
    pub const write_set_passphrase = __root.archive_write_set_passphrase;
    pub const write_set_passphrase_callback = __root.archive_write_set_passphrase_callback;
    pub const write_disk_set_skip_file = __root.archive_write_disk_set_skip_file;
    pub const write_disk_set_options = __root.archive_write_disk_set_options;
    pub const write_disk_set_standard_lookup = __root.archive_write_disk_set_standard_lookup;
    pub const write_disk_set_group_lookup = __root.archive_write_disk_set_group_lookup;
    pub const write_disk_set_user_lookup = __root.archive_write_disk_set_user_lookup;
    pub const write_disk_gid = __root.archive_write_disk_gid;
    pub const write_disk_uid = __root.archive_write_disk_uid;
    pub const read_disk_set_symlink_logical = __root.archive_read_disk_set_symlink_logical;
    pub const read_disk_set_symlink_physical = __root.archive_read_disk_set_symlink_physical;
    pub const read_disk_set_symlink_hybrid = __root.archive_read_disk_set_symlink_hybrid;
    pub const read_disk_entry_from_file = __root.archive_read_disk_entry_from_file;
    pub const read_disk_gname = __root.archive_read_disk_gname;
    pub const read_disk_uname = __root.archive_read_disk_uname;
    pub const read_disk_set_standard_lookup = __root.archive_read_disk_set_standard_lookup;
    pub const read_disk_set_gname_lookup = __root.archive_read_disk_set_gname_lookup;
    pub const read_disk_set_uname_lookup = __root.archive_read_disk_set_uname_lookup;
    pub const read_disk_open = __root.archive_read_disk_open;
    pub const read_disk_open_w = __root.archive_read_disk_open_w;
    pub const read_disk_descend = __root.archive_read_disk_descend;
    pub const read_disk_can_descend = __root.archive_read_disk_can_descend;
    pub const read_disk_current_filesystem = __root.archive_read_disk_current_filesystem;
    pub const read_disk_current_filesystem_is_synthetic = __root.archive_read_disk_current_filesystem_is_synthetic;
    pub const read_disk_current_filesystem_is_remote = __root.archive_read_disk_current_filesystem_is_remote;
    pub const read_disk_set_atime_restored = __root.archive_read_disk_set_atime_restored;
    pub const read_disk_set_behavior = __root.archive_read_disk_set_behavior;
    pub const read_disk_set_matching = __root.archive_read_disk_set_matching;
    pub const read_disk_set_metadata_filter_callback = __root.archive_read_disk_set_metadata_filter_callback;
    pub const filter_count = __root.archive_filter_count;
    pub const filter_bytes = __root.archive_filter_bytes;
    pub const filter_code = __root.archive_filter_code;
    pub const filter_name = __root.archive_filter_name;
    pub const position_compressed = __root.archive_position_compressed;
    pub const position_uncompressed = __root.archive_position_uncompressed;
    pub const compression_name = __root.archive_compression_name;
    pub const compression = __root.archive_compression;
    pub const errno = __root.archive_errno;
    pub const error_string = __root.archive_error_string;
    pub const format_name = __root.archive_format_name;
    pub const format = __root.archive_format;
    pub const clear_error = __root.archive_clear_error;
    pub const set_error = __root.archive_set_error;
    pub const copy_error = __root.archive_copy_error;
    pub const file_count = __root.archive_file_count;
    pub const match_free = __root.archive_match_free;
    pub const match_excluded = __root.archive_match_excluded;
    pub const match_path_excluded = __root.archive_match_path_excluded;
    pub const match_set_inclusion_recursion = __root.archive_match_set_inclusion_recursion;
    pub const match_exclude_pattern = __root.archive_match_exclude_pattern;
    pub const match_exclude_pattern_w = __root.archive_match_exclude_pattern_w;
    pub const match_exclude_pattern_from_file = __root.archive_match_exclude_pattern_from_file;
    pub const match_exclude_pattern_from_file_w = __root.archive_match_exclude_pattern_from_file_w;
    pub const match_include_pattern = __root.archive_match_include_pattern;
    pub const match_include_pattern_w = __root.archive_match_include_pattern_w;
    pub const match_include_pattern_from_file = __root.archive_match_include_pattern_from_file;
    pub const match_include_pattern_from_file_w = __root.archive_match_include_pattern_from_file_w;
    pub const match_path_unmatched_inclusions = __root.archive_match_path_unmatched_inclusions;
    pub const match_path_unmatched_inclusions_next = __root.archive_match_path_unmatched_inclusions_next;
    pub const match_path_unmatched_inclusions_next_w = __root.archive_match_path_unmatched_inclusions_next_w;
    pub const match_time_excluded = __root.archive_match_time_excluded;
    pub const match_include_time = __root.archive_match_include_time;
    pub const match_include_date = __root.archive_match_include_date;
    pub const match_include_date_w = __root.archive_match_include_date_w;
    pub const match_include_file_time = __root.archive_match_include_file_time;
    pub const match_include_file_time_w = __root.archive_match_include_file_time_w;
    pub const match_exclude_entry = __root.archive_match_exclude_entry;
    pub const match_owner_excluded = __root.archive_match_owner_excluded;
    pub const match_include_uid = __root.archive_match_include_uid;
    pub const match_include_gid = __root.archive_match_include_gid;
    pub const match_include_uname = __root.archive_match_include_uname;
    pub const match_include_uname_w = __root.archive_match_include_uname_w;
    pub const match_include_gname = __root.archive_match_include_gname;
    pub const match_include_gname_w = __root.archive_match_include_gname_w;
    pub const entry_new2 = __root.archive_entry_new2;
};
pub const struct_archive_entry = opaque {
    pub const archive_entry_clear = __root.archive_entry_clear;
    pub const archive_entry_clone = __root.archive_entry_clone;
    pub const archive_entry_free = __root.archive_entry_free;
    pub const archive_entry_atime = __root.archive_entry_atime;
    pub const archive_entry_atime_nsec = __root.archive_entry_atime_nsec;
    pub const archive_entry_atime_is_set = __root.archive_entry_atime_is_set;
    pub const archive_entry_birthtime = __root.archive_entry_birthtime;
    pub const archive_entry_birthtime_nsec = __root.archive_entry_birthtime_nsec;
    pub const archive_entry_birthtime_is_set = __root.archive_entry_birthtime_is_set;
    pub const archive_entry_ctime = __root.archive_entry_ctime;
    pub const archive_entry_ctime_nsec = __root.archive_entry_ctime_nsec;
    pub const archive_entry_ctime_is_set = __root.archive_entry_ctime_is_set;
    pub const archive_entry_dev = __root.archive_entry_dev;
    pub const archive_entry_dev_is_set = __root.archive_entry_dev_is_set;
    pub const archive_entry_devmajor = __root.archive_entry_devmajor;
    pub const archive_entry_devminor = __root.archive_entry_devminor;
    pub const archive_entry_filetype = __root.archive_entry_filetype;
    pub const archive_entry_filetype_is_set = __root.archive_entry_filetype_is_set;
    pub const archive_entry_fflags = __root.archive_entry_fflags;
    pub const archive_entry_fflags_text = __root.archive_entry_fflags_text;
    pub const archive_entry_gid = __root.archive_entry_gid;
    pub const archive_entry_gid_is_set = __root.archive_entry_gid_is_set;
    pub const archive_entry_gname = __root.archive_entry_gname;
    pub const archive_entry_gname_utf8 = __root.archive_entry_gname_utf8;
    pub const archive_entry_gname_w = __root.archive_entry_gname_w;
    pub const archive_entry_set_link_to_hardlink = __root.archive_entry_set_link_to_hardlink;
    pub const archive_entry_hardlink = __root.archive_entry_hardlink;
    pub const archive_entry_hardlink_utf8 = __root.archive_entry_hardlink_utf8;
    pub const archive_entry_hardlink_w = __root.archive_entry_hardlink_w;
    pub const archive_entry_hardlink_is_set = __root.archive_entry_hardlink_is_set;
    pub const archive_entry_ino = __root.archive_entry_ino;
    pub const archive_entry_ino64 = __root.archive_entry_ino64;
    pub const archive_entry_ino_is_set = __root.archive_entry_ino_is_set;
    pub const archive_entry_mode = __root.archive_entry_mode;
    pub const archive_entry_mtime = __root.archive_entry_mtime;
    pub const archive_entry_mtime_nsec = __root.archive_entry_mtime_nsec;
    pub const archive_entry_mtime_is_set = __root.archive_entry_mtime_is_set;
    pub const archive_entry_nlink = __root.archive_entry_nlink;
    pub const archive_entry_pathname = __root.archive_entry_pathname;
    pub const archive_entry_pathname_utf8 = __root.archive_entry_pathname_utf8;
    pub const archive_entry_pathname_w = __root.archive_entry_pathname_w;
    pub const archive_entry_perm = __root.archive_entry_perm;
    pub const archive_entry_perm_is_set = __root.archive_entry_perm_is_set;
    pub const archive_entry_rdev_is_set = __root.archive_entry_rdev_is_set;
    pub const archive_entry_rdev = __root.archive_entry_rdev;
    pub const archive_entry_rdevmajor = __root.archive_entry_rdevmajor;
    pub const archive_entry_rdevminor = __root.archive_entry_rdevminor;
    pub const archive_entry_sourcepath = __root.archive_entry_sourcepath;
    pub const archive_entry_sourcepath_w = __root.archive_entry_sourcepath_w;
    pub const archive_entry_size = __root.archive_entry_size;
    pub const archive_entry_size_is_set = __root.archive_entry_size_is_set;
    pub const archive_entry_strmode = __root.archive_entry_strmode;
    pub const archive_entry_set_link_to_symlink = __root.archive_entry_set_link_to_symlink;
    pub const archive_entry_symlink = __root.archive_entry_symlink;
    pub const archive_entry_symlink_utf8 = __root.archive_entry_symlink_utf8;
    pub const archive_entry_symlink_type = __root.archive_entry_symlink_type;
    pub const archive_entry_symlink_w = __root.archive_entry_symlink_w;
    pub const archive_entry_uid = __root.archive_entry_uid;
    pub const archive_entry_uid_is_set = __root.archive_entry_uid_is_set;
    pub const archive_entry_uname = __root.archive_entry_uname;
    pub const archive_entry_uname_utf8 = __root.archive_entry_uname_utf8;
    pub const archive_entry_uname_w = __root.archive_entry_uname_w;
    pub const archive_entry_is_data_encrypted = __root.archive_entry_is_data_encrypted;
    pub const archive_entry_is_metadata_encrypted = __root.archive_entry_is_metadata_encrypted;
    pub const archive_entry_is_encrypted = __root.archive_entry_is_encrypted;
    pub const archive_entry_set_atime = __root.archive_entry_set_atime;
    pub const archive_entry_unset_atime = __root.archive_entry_unset_atime;
    pub const archive_entry_set_birthtime = __root.archive_entry_set_birthtime;
    pub const archive_entry_unset_birthtime = __root.archive_entry_unset_birthtime;
    pub const archive_entry_set_ctime = __root.archive_entry_set_ctime;
    pub const archive_entry_unset_ctime = __root.archive_entry_unset_ctime;
    pub const archive_entry_set_dev = __root.archive_entry_set_dev;
    pub const archive_entry_set_devmajor = __root.archive_entry_set_devmajor;
    pub const archive_entry_set_devminor = __root.archive_entry_set_devminor;
    pub const archive_entry_set_filetype = __root.archive_entry_set_filetype;
    pub const archive_entry_set_fflags = __root.archive_entry_set_fflags;
    pub const archive_entry_copy_fflags_text = __root.archive_entry_copy_fflags_text;
    pub const archive_entry_copy_fflags_text_len = __root.archive_entry_copy_fflags_text_len;
    pub const archive_entry_copy_fflags_text_w = __root.archive_entry_copy_fflags_text_w;
    pub const archive_entry_set_gid = __root.archive_entry_set_gid;
    pub const archive_entry_set_gname = __root.archive_entry_set_gname;
    pub const archive_entry_set_gname_utf8 = __root.archive_entry_set_gname_utf8;
    pub const archive_entry_copy_gname = __root.archive_entry_copy_gname;
    pub const archive_entry_copy_gname_w = __root.archive_entry_copy_gname_w;
    pub const archive_entry_update_gname_utf8 = __root.archive_entry_update_gname_utf8;
    pub const archive_entry_set_hardlink = __root.archive_entry_set_hardlink;
    pub const archive_entry_set_hardlink_utf8 = __root.archive_entry_set_hardlink_utf8;
    pub const archive_entry_copy_hardlink = __root.archive_entry_copy_hardlink;
    pub const archive_entry_copy_hardlink_w = __root.archive_entry_copy_hardlink_w;
    pub const archive_entry_update_hardlink_utf8 = __root.archive_entry_update_hardlink_utf8;
    pub const archive_entry_set_ino = __root.archive_entry_set_ino;
    pub const archive_entry_set_ino64 = __root.archive_entry_set_ino64;
    pub const archive_entry_set_link = __root.archive_entry_set_link;
    pub const archive_entry_set_link_utf8 = __root.archive_entry_set_link_utf8;
    pub const archive_entry_copy_link = __root.archive_entry_copy_link;
    pub const archive_entry_copy_link_w = __root.archive_entry_copy_link_w;
    pub const archive_entry_update_link_utf8 = __root.archive_entry_update_link_utf8;
    pub const archive_entry_set_mode = __root.archive_entry_set_mode;
    pub const archive_entry_set_mtime = __root.archive_entry_set_mtime;
    pub const archive_entry_unset_mtime = __root.archive_entry_unset_mtime;
    pub const archive_entry_set_nlink = __root.archive_entry_set_nlink;
    pub const archive_entry_set_pathname = __root.archive_entry_set_pathname;
    pub const archive_entry_set_pathname_utf8 = __root.archive_entry_set_pathname_utf8;
    pub const archive_entry_copy_pathname = __root.archive_entry_copy_pathname;
    pub const archive_entry_copy_pathname_w = __root.archive_entry_copy_pathname_w;
    pub const archive_entry_update_pathname_utf8 = __root.archive_entry_update_pathname_utf8;
    pub const archive_entry_set_perm = __root.archive_entry_set_perm;
    pub const archive_entry_set_rdev = __root.archive_entry_set_rdev;
    pub const archive_entry_set_rdevmajor = __root.archive_entry_set_rdevmajor;
    pub const archive_entry_set_rdevminor = __root.archive_entry_set_rdevminor;
    pub const archive_entry_set_size = __root.archive_entry_set_size;
    pub const archive_entry_unset_size = __root.archive_entry_unset_size;
    pub const archive_entry_copy_sourcepath = __root.archive_entry_copy_sourcepath;
    pub const archive_entry_copy_sourcepath_w = __root.archive_entry_copy_sourcepath_w;
    pub const archive_entry_set_symlink = __root.archive_entry_set_symlink;
    pub const archive_entry_set_symlink_type = __root.archive_entry_set_symlink_type;
    pub const archive_entry_set_symlink_utf8 = __root.archive_entry_set_symlink_utf8;
    pub const archive_entry_copy_symlink = __root.archive_entry_copy_symlink;
    pub const archive_entry_copy_symlink_w = __root.archive_entry_copy_symlink_w;
    pub const archive_entry_update_symlink_utf8 = __root.archive_entry_update_symlink_utf8;
    pub const archive_entry_set_uid = __root.archive_entry_set_uid;
    pub const archive_entry_set_uname = __root.archive_entry_set_uname;
    pub const archive_entry_set_uname_utf8 = __root.archive_entry_set_uname_utf8;
    pub const archive_entry_copy_uname = __root.archive_entry_copy_uname;
    pub const archive_entry_copy_uname_w = __root.archive_entry_copy_uname_w;
    pub const archive_entry_update_uname_utf8 = __root.archive_entry_update_uname_utf8;
    pub const archive_entry_set_is_data_encrypted = __root.archive_entry_set_is_data_encrypted;
    pub const archive_entry_set_is_metadata_encrypted = __root.archive_entry_set_is_metadata_encrypted;
    pub const archive_entry_stat = __root.archive_entry_stat;
    pub const archive_entry_copy_stat = __root.archive_entry_copy_stat;
    pub const archive_entry_mac_metadata = __root.archive_entry_mac_metadata;
    pub const archive_entry_copy_mac_metadata = __root.archive_entry_copy_mac_metadata;
    pub const archive_entry_digest = __root.archive_entry_digest;
    pub const archive_entry_set_digest = __root.archive_entry_set_digest;
    pub const archive_entry_acl_clear = __root.archive_entry_acl_clear;
    pub const archive_entry_acl_add_entry = __root.archive_entry_acl_add_entry;
    pub const archive_entry_acl_add_entry_w = __root.archive_entry_acl_add_entry_w;
    pub const archive_entry_acl_reset = __root.archive_entry_acl_reset;
    pub const archive_entry_acl_next = __root.archive_entry_acl_next;
    pub const archive_entry_acl_to_text_w = __root.archive_entry_acl_to_text_w;
    pub const archive_entry_acl_to_text = __root.archive_entry_acl_to_text;
    pub const archive_entry_acl_from_text_w = __root.archive_entry_acl_from_text_w;
    pub const archive_entry_acl_from_text = __root.archive_entry_acl_from_text;
    pub const archive_entry_acl_text_w = __root.archive_entry_acl_text_w;
    pub const archive_entry_acl_text = __root.archive_entry_acl_text;
    pub const archive_entry_acl_types = __root.archive_entry_acl_types;
    pub const archive_entry_acl_count = __root.archive_entry_acl_count;
    pub const archive_entry_acl = __root.archive_entry_acl;
    pub const archive_entry_xattr_clear = __root.archive_entry_xattr_clear;
    pub const archive_entry_xattr_add_entry = __root.archive_entry_xattr_add_entry;
    pub const archive_entry_xattr_count = __root.archive_entry_xattr_count;
    pub const archive_entry_xattr_reset = __root.archive_entry_xattr_reset;
    pub const archive_entry_xattr_next = __root.archive_entry_xattr_next;
    pub const archive_entry_sparse_clear = __root.archive_entry_sparse_clear;
    pub const archive_entry_sparse_add_entry = __root.archive_entry_sparse_add_entry;
    pub const archive_entry_sparse_count = __root.archive_entry_sparse_count;
    pub const archive_entry_sparse_reset = __root.archive_entry_sparse_reset;
    pub const archive_entry_sparse_next = __root.archive_entry_sparse_next;
    pub const clear = __root.archive_entry_clear;
    pub const clone = __root.archive_entry_clone;
    pub const atime = __root.archive_entry_atime;
    pub const atime_nsec = __root.archive_entry_atime_nsec;
    pub const atime_is_set = __root.archive_entry_atime_is_set;
    pub const birthtime = __root.archive_entry_birthtime;
    pub const birthtime_nsec = __root.archive_entry_birthtime_nsec;
    pub const birthtime_is_set = __root.archive_entry_birthtime_is_set;
    pub const ctime_nsec = __root.archive_entry_ctime_nsec;
    pub const ctime_is_set = __root.archive_entry_ctime_is_set;
    pub const dev = __root.archive_entry_dev;
    pub const dev_is_set = __root.archive_entry_dev_is_set;
    pub const devmajor = __root.archive_entry_devmajor;
    pub const devminor = __root.archive_entry_devminor;
    pub const filetype = __root.archive_entry_filetype;
    pub const filetype_is_set = __root.archive_entry_filetype_is_set;
    pub const fflags = __root.archive_entry_fflags;
    pub const fflags_text = __root.archive_entry_fflags_text;
    pub const gid = __root.archive_entry_gid;
    pub const gid_is_set = __root.archive_entry_gid_is_set;
    pub const gname = __root.archive_entry_gname;
    pub const gname_utf8 = __root.archive_entry_gname_utf8;
    pub const gname_w = __root.archive_entry_gname_w;
    pub const set_link_to_hardlink = __root.archive_entry_set_link_to_hardlink;
    pub const hardlink = __root.archive_entry_hardlink;
    pub const hardlink_utf8 = __root.archive_entry_hardlink_utf8;
    pub const hardlink_w = __root.archive_entry_hardlink_w;
    pub const hardlink_is_set = __root.archive_entry_hardlink_is_set;
    pub const ino = __root.archive_entry_ino;
    pub const ino64 = __root.archive_entry_ino64;
    pub const ino_is_set = __root.archive_entry_ino_is_set;
    pub const mode = __root.archive_entry_mode;
    pub const mtime = __root.archive_entry_mtime;
    pub const mtime_nsec = __root.archive_entry_mtime_nsec;
    pub const mtime_is_set = __root.archive_entry_mtime_is_set;
    pub const nlink = __root.archive_entry_nlink;
    pub const pathname = __root.archive_entry_pathname;
    pub const pathname_utf8 = __root.archive_entry_pathname_utf8;
    pub const pathname_w = __root.archive_entry_pathname_w;
    pub const perm = __root.archive_entry_perm;
    pub const perm_is_set = __root.archive_entry_perm_is_set;
    pub const rdev_is_set = __root.archive_entry_rdev_is_set;
    pub const rdev = __root.archive_entry_rdev;
    pub const rdevmajor = __root.archive_entry_rdevmajor;
    pub const rdevminor = __root.archive_entry_rdevminor;
    pub const sourcepath = __root.archive_entry_sourcepath;
    pub const sourcepath_w = __root.archive_entry_sourcepath_w;
    pub const size = __root.archive_entry_size;
    pub const size_is_set = __root.archive_entry_size_is_set;
    pub const strmode = __root.archive_entry_strmode;
    pub const set_link_to_symlink = __root.archive_entry_set_link_to_symlink;
    pub const symlink_utf8 = __root.archive_entry_symlink_utf8;
    pub const symlink_type = __root.archive_entry_symlink_type;
    pub const symlink_w = __root.archive_entry_symlink_w;
    pub const uid = __root.archive_entry_uid;
    pub const uid_is_set = __root.archive_entry_uid_is_set;
    pub const uname = __root.archive_entry_uname;
    pub const uname_utf8 = __root.archive_entry_uname_utf8;
    pub const uname_w = __root.archive_entry_uname_w;
    pub const is_data_encrypted = __root.archive_entry_is_data_encrypted;
    pub const is_metadata_encrypted = __root.archive_entry_is_metadata_encrypted;
    pub const is_encrypted = __root.archive_entry_is_encrypted;
    pub const set_atime = __root.archive_entry_set_atime;
    pub const unset_atime = __root.archive_entry_unset_atime;
    pub const set_birthtime = __root.archive_entry_set_birthtime;
    pub const unset_birthtime = __root.archive_entry_unset_birthtime;
    pub const set_ctime = __root.archive_entry_set_ctime;
    pub const unset_ctime = __root.archive_entry_unset_ctime;
    pub const set_dev = __root.archive_entry_set_dev;
    pub const set_devmajor = __root.archive_entry_set_devmajor;
    pub const set_devminor = __root.archive_entry_set_devminor;
    pub const set_filetype = __root.archive_entry_set_filetype;
    pub const set_fflags = __root.archive_entry_set_fflags;
    pub const copy_fflags_text = __root.archive_entry_copy_fflags_text;
    pub const copy_fflags_text_len = __root.archive_entry_copy_fflags_text_len;
    pub const copy_fflags_text_w = __root.archive_entry_copy_fflags_text_w;
    pub const set_gid = __root.archive_entry_set_gid;
    pub const set_gname = __root.archive_entry_set_gname;
    pub const set_gname_utf8 = __root.archive_entry_set_gname_utf8;
    pub const copy_gname = __root.archive_entry_copy_gname;
    pub const copy_gname_w = __root.archive_entry_copy_gname_w;
    pub const update_gname_utf8 = __root.archive_entry_update_gname_utf8;
    pub const set_hardlink = __root.archive_entry_set_hardlink;
    pub const set_hardlink_utf8 = __root.archive_entry_set_hardlink_utf8;
    pub const copy_hardlink = __root.archive_entry_copy_hardlink;
    pub const copy_hardlink_w = __root.archive_entry_copy_hardlink_w;
    pub const update_hardlink_utf8 = __root.archive_entry_update_hardlink_utf8;
    pub const set_ino = __root.archive_entry_set_ino;
    pub const set_ino64 = __root.archive_entry_set_ino64;
    pub const set_link = __root.archive_entry_set_link;
    pub const set_link_utf8 = __root.archive_entry_set_link_utf8;
    pub const copy_link = __root.archive_entry_copy_link;
    pub const copy_link_w = __root.archive_entry_copy_link_w;
    pub const update_link_utf8 = __root.archive_entry_update_link_utf8;
    pub const set_mode = __root.archive_entry_set_mode;
    pub const set_mtime = __root.archive_entry_set_mtime;
    pub const unset_mtime = __root.archive_entry_unset_mtime;
    pub const set_nlink = __root.archive_entry_set_nlink;
    pub const set_pathname = __root.archive_entry_set_pathname;
    pub const set_pathname_utf8 = __root.archive_entry_set_pathname_utf8;
    pub const copy_pathname = __root.archive_entry_copy_pathname;
    pub const copy_pathname_w = __root.archive_entry_copy_pathname_w;
    pub const update_pathname_utf8 = __root.archive_entry_update_pathname_utf8;
    pub const set_perm = __root.archive_entry_set_perm;
    pub const set_rdev = __root.archive_entry_set_rdev;
    pub const set_rdevmajor = __root.archive_entry_set_rdevmajor;
    pub const set_rdevminor = __root.archive_entry_set_rdevminor;
    pub const set_size = __root.archive_entry_set_size;
    pub const unset_size = __root.archive_entry_unset_size;
    pub const copy_sourcepath = __root.archive_entry_copy_sourcepath;
    pub const copy_sourcepath_w = __root.archive_entry_copy_sourcepath_w;
    pub const set_symlink = __root.archive_entry_set_symlink;
    pub const set_symlink_type = __root.archive_entry_set_symlink_type;
    pub const set_symlink_utf8 = __root.archive_entry_set_symlink_utf8;
    pub const copy_symlink = __root.archive_entry_copy_symlink;
    pub const copy_symlink_w = __root.archive_entry_copy_symlink_w;
    pub const update_symlink_utf8 = __root.archive_entry_update_symlink_utf8;
    pub const set_uid = __root.archive_entry_set_uid;
    pub const set_uname = __root.archive_entry_set_uname;
    pub const set_uname_utf8 = __root.archive_entry_set_uname_utf8;
    pub const copy_uname = __root.archive_entry_copy_uname;
    pub const copy_uname_w = __root.archive_entry_copy_uname_w;
    pub const update_uname_utf8 = __root.archive_entry_update_uname_utf8;
    pub const set_is_data_encrypted = __root.archive_entry_set_is_data_encrypted;
    pub const set_is_metadata_encrypted = __root.archive_entry_set_is_metadata_encrypted;
    pub const copy_stat = __root.archive_entry_copy_stat;
    pub const mac_metadata = __root.archive_entry_mac_metadata;
    pub const copy_mac_metadata = __root.archive_entry_copy_mac_metadata;
    pub const digest = __root.archive_entry_digest;
    pub const set_digest = __root.archive_entry_set_digest;
    pub const acl_clear = __root.archive_entry_acl_clear;
    pub const acl_add_entry = __root.archive_entry_acl_add_entry;
    pub const acl_add_entry_w = __root.archive_entry_acl_add_entry_w;
    pub const acl_reset = __root.archive_entry_acl_reset;
    pub const acl_next = __root.archive_entry_acl_next;
    pub const acl_to_text_w = __root.archive_entry_acl_to_text_w;
    pub const acl_to_text = __root.archive_entry_acl_to_text;
    pub const acl_from_text_w = __root.archive_entry_acl_from_text_w;
    pub const acl_from_text = __root.archive_entry_acl_from_text;
    pub const acl_text_w = __root.archive_entry_acl_text_w;
    pub const acl_text = __root.archive_entry_acl_text;
    pub const acl_types = __root.archive_entry_acl_types;
    pub const acl_count = __root.archive_entry_acl_count;
    pub const acl = __root.archive_entry_acl;
    pub const xattr_clear = __root.archive_entry_xattr_clear;
    pub const xattr_add_entry = __root.archive_entry_xattr_add_entry;
    pub const xattr_count = __root.archive_entry_xattr_count;
    pub const xattr_reset = __root.archive_entry_xattr_reset;
    pub const xattr_next = __root.archive_entry_xattr_next;
    pub const sparse_clear = __root.archive_entry_sparse_clear;
    pub const sparse_add_entry = __root.archive_entry_sparse_add_entry;
    pub const sparse_count = __root.archive_entry_sparse_count;
    pub const sparse_reset = __root.archive_entry_sparse_reset;
    pub const sparse_next = __root.archive_entry_sparse_next;
};
pub const archive_read_callback = fn (?*struct_archive, _client_data: ?*anyopaque, _buffer: [*c]?*const anyopaque) callconv(.c) la_ssize_t;
pub const archive_skip_callback = fn (?*struct_archive, _client_data: ?*anyopaque, request: la_int64_t) callconv(.c) la_int64_t;
pub const archive_seek_callback = fn (?*struct_archive, _client_data: ?*anyopaque, offset: la_int64_t, whence: c_int) callconv(.c) la_int64_t;
pub const archive_write_callback = fn (?*struct_archive, _client_data: ?*anyopaque, _buffer: ?*const anyopaque, _length: usize) callconv(.c) la_ssize_t;
pub const archive_open_callback = fn (?*struct_archive, _client_data: ?*anyopaque) callconv(.c) c_int;
pub const archive_close_callback = fn (?*struct_archive, _client_data: ?*anyopaque) callconv(.c) c_int;
pub const archive_free_callback = fn (?*struct_archive, _client_data: ?*anyopaque) callconv(.c) c_int;
pub const archive_switch_callback = fn (?*struct_archive, _client_data1: ?*anyopaque, _client_data2: ?*anyopaque) callconv(.c) c_int;
pub const archive_passphrase_callback = fn (?*struct_archive, _client_data: ?*anyopaque) callconv(.c) [*c]const u8;
pub extern fn archive_read_new() ?*struct_archive;
pub extern fn archive_read_support_compression_all(?*struct_archive) c_int;
pub extern fn archive_read_support_compression_bzip2(?*struct_archive) c_int;
pub extern fn archive_read_support_compression_compress(?*struct_archive) c_int;
pub extern fn archive_read_support_compression_gzip(?*struct_archive) c_int;
pub extern fn archive_read_support_compression_lzip(?*struct_archive) c_int;
pub extern fn archive_read_support_compression_lzma(?*struct_archive) c_int;
pub extern fn archive_read_support_compression_none(?*struct_archive) c_int;
pub extern fn archive_read_support_compression_program(?*struct_archive, command: [*c]const u8) c_int;
pub extern fn archive_read_support_compression_program_signature(?*struct_archive, [*c]const u8, ?*const anyopaque, usize) c_int;
pub extern fn archive_read_support_compression_rpm(?*struct_archive) c_int;
pub extern fn archive_read_support_compression_uu(?*struct_archive) c_int;
pub extern fn archive_read_support_compression_xz(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_all(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_by_code(?*struct_archive, c_int) c_int;
pub extern fn archive_read_support_filter_bzip2(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_compress(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_gzip(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_grzip(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_lrzip(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_lz4(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_lzip(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_lzma(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_lzop(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_none(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_program(?*struct_archive, command: [*c]const u8) c_int;
pub extern fn archive_read_support_filter_program_signature(?*struct_archive, [*c]const u8, ?*const anyopaque, usize) c_int;
pub extern fn archive_read_support_filter_rpm(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_uu(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_xz(?*struct_archive) c_int;
pub extern fn archive_read_support_filter_zstd(?*struct_archive) c_int;
pub extern fn archive_read_support_format_7zip(?*struct_archive) c_int;
pub extern fn archive_read_support_format_all(?*struct_archive) c_int;
pub extern fn archive_read_support_format_ar(?*struct_archive) c_int;
pub extern fn archive_read_support_format_by_code(?*struct_archive, c_int) c_int;
pub extern fn archive_read_support_format_cab(?*struct_archive) c_int;
pub extern fn archive_read_support_format_cpio(?*struct_archive) c_int;
pub extern fn archive_read_support_format_empty(?*struct_archive) c_int;
pub extern fn archive_read_support_format_gnutar(?*struct_archive) c_int;
pub extern fn archive_read_support_format_iso9660(?*struct_archive) c_int;
pub extern fn archive_read_support_format_lha(?*struct_archive) c_int;
pub extern fn archive_read_support_format_mtree(?*struct_archive) c_int;
pub extern fn archive_read_support_format_rar(?*struct_archive) c_int;
pub extern fn archive_read_support_format_rar5(?*struct_archive) c_int;
pub extern fn archive_read_support_format_raw(?*struct_archive) c_int;
pub extern fn archive_read_support_format_tar(?*struct_archive) c_int;
pub extern fn archive_read_support_format_warc(?*struct_archive) c_int;
pub extern fn archive_read_support_format_xar(?*struct_archive) c_int;
pub extern fn archive_read_support_format_zip(?*struct_archive) c_int;
pub extern fn archive_read_support_format_zip_streamable(?*struct_archive) c_int;
pub extern fn archive_read_support_format_zip_seekable(?*struct_archive) c_int;
pub extern fn archive_read_set_format(?*struct_archive, c_int) c_int;
pub extern fn archive_read_append_filter(?*struct_archive, c_int) c_int;
pub extern fn archive_read_append_filter_program(?*struct_archive, [*c]const u8) c_int;
pub extern fn archive_read_append_filter_program_signature(?*struct_archive, [*c]const u8, ?*const anyopaque, usize) c_int;
pub extern fn archive_read_set_open_callback(?*struct_archive, ?*const archive_open_callback) c_int;
pub extern fn archive_read_set_read_callback(?*struct_archive, ?*const archive_read_callback) c_int;
pub extern fn archive_read_set_seek_callback(?*struct_archive, ?*const archive_seek_callback) c_int;
pub extern fn archive_read_set_skip_callback(?*struct_archive, ?*const archive_skip_callback) c_int;
pub extern fn archive_read_set_close_callback(?*struct_archive, ?*const archive_close_callback) c_int;
pub extern fn archive_read_set_switch_callback(?*struct_archive, ?*const archive_switch_callback) c_int;
pub extern fn archive_read_set_callback_data(?*struct_archive, ?*anyopaque) c_int;
pub extern fn archive_read_set_callback_data2(?*struct_archive, ?*anyopaque, c_uint) c_int;
pub extern fn archive_read_add_callback_data(?*struct_archive, ?*anyopaque, c_uint) c_int;
pub extern fn archive_read_append_callback_data(?*struct_archive, ?*anyopaque) c_int;
pub extern fn archive_read_prepend_callback_data(?*struct_archive, ?*anyopaque) c_int;
pub extern fn archive_read_open1(?*struct_archive) c_int;
pub extern fn archive_read_open(?*struct_archive, _client_data: ?*anyopaque, ?*const archive_open_callback, ?*const archive_read_callback, ?*const archive_close_callback) c_int;
pub extern fn archive_read_open2(?*struct_archive, _client_data: ?*anyopaque, ?*const archive_open_callback, ?*const archive_read_callback, ?*const archive_skip_callback, ?*const archive_close_callback) c_int;
pub extern fn archive_read_open_filename(?*struct_archive, _filename: [*c]const u8, _block_size: usize) c_int;
pub extern fn archive_read_open_filenames(?*struct_archive, _filenames: [*c][*c]const u8, _block_size: usize) c_int;
pub extern fn archive_read_open_filename_w(?*struct_archive, _filename: [*c]const wchar_t, _block_size: usize) c_int;
pub extern fn archive_read_open_file(?*struct_archive, _filename: [*c]const u8, _block_size: usize) c_int;
pub extern fn archive_read_open_memory(?*struct_archive, buff: ?*const anyopaque, size: usize) c_int;
pub extern fn archive_read_open_memory2(a: ?*struct_archive, buff: ?*const anyopaque, size: usize, read_size: usize) c_int;
pub extern fn archive_read_open_fd(?*struct_archive, _fd: c_int, _block_size: usize) c_int;
pub extern fn archive_read_open_FILE(?*struct_archive, _file: ?*FILE) c_int;
pub extern fn archive_read_next_header(?*struct_archive, [*c]?*struct_archive_entry) c_int;
pub extern fn archive_read_next_header2(?*struct_archive, ?*struct_archive_entry) c_int;
pub extern fn archive_read_header_position(?*struct_archive) la_int64_t;
pub extern fn archive_read_has_encrypted_entries(?*struct_archive) c_int;
pub extern fn archive_read_format_capabilities(?*struct_archive) c_int;
pub extern fn archive_read_data(?*struct_archive, ?*anyopaque, usize) la_ssize_t;
pub extern fn archive_seek_data(?*struct_archive, la_int64_t, c_int) la_int64_t;
pub extern fn archive_read_data_block(a: ?*struct_archive, buff: [*c]?*const anyopaque, size: [*c]usize, offset: [*c]la_int64_t) c_int;
pub extern fn archive_read_data_skip(?*struct_archive) c_int;
pub extern fn archive_read_data_into_fd(?*struct_archive, fd: c_int) c_int;
pub extern fn archive_read_set_format_option(_a: ?*struct_archive, m: [*c]const u8, o: [*c]const u8, v: [*c]const u8) c_int;
pub extern fn archive_read_set_filter_option(_a: ?*struct_archive, m: [*c]const u8, o: [*c]const u8, v: [*c]const u8) c_int;
pub extern fn archive_read_set_option(_a: ?*struct_archive, m: [*c]const u8, o: [*c]const u8, v: [*c]const u8) c_int;
pub extern fn archive_read_set_options(_a: ?*struct_archive, opts: [*c]const u8) c_int;
pub extern fn archive_read_add_passphrase(?*struct_archive, [*c]const u8) c_int;
pub extern fn archive_read_set_passphrase_callback(?*struct_archive, client_data: ?*anyopaque, ?*const archive_passphrase_callback) c_int;
pub extern fn archive_read_extract(?*struct_archive, ?*struct_archive_entry, flags: c_int) c_int;
pub extern fn archive_read_extract2(?*struct_archive, ?*struct_archive_entry, ?*struct_archive) c_int;
pub extern fn archive_read_extract_set_progress_callback(?*struct_archive, _progress_func: ?*const fn (?*anyopaque) callconv(.c) void, _user_data: ?*anyopaque) void;
pub extern fn archive_read_extract_set_skip_file(?*struct_archive, la_int64_t, la_int64_t) void;
pub extern fn archive_read_close(?*struct_archive) c_int;
pub extern fn archive_read_free(?*struct_archive) c_int;
pub extern fn archive_read_finish(?*struct_archive) c_int;
pub extern fn archive_write_new() ?*struct_archive;
pub extern fn archive_write_set_bytes_per_block(?*struct_archive, bytes_per_block: c_int) c_int;
pub extern fn archive_write_get_bytes_per_block(?*struct_archive) c_int;
pub extern fn archive_write_set_bytes_in_last_block(?*struct_archive, bytes_in_last_block: c_int) c_int;
pub extern fn archive_write_get_bytes_in_last_block(?*struct_archive) c_int;
pub extern fn archive_write_set_skip_file(?*struct_archive, la_int64_t, la_int64_t) c_int;
pub extern fn archive_write_set_compression_bzip2(?*struct_archive) c_int;
pub extern fn archive_write_set_compression_compress(?*struct_archive) c_int;
pub extern fn archive_write_set_compression_gzip(?*struct_archive) c_int;
pub extern fn archive_write_set_compression_lzip(?*struct_archive) c_int;
pub extern fn archive_write_set_compression_lzma(?*struct_archive) c_int;
pub extern fn archive_write_set_compression_none(?*struct_archive) c_int;
pub extern fn archive_write_set_compression_program(?*struct_archive, cmd: [*c]const u8) c_int;
pub extern fn archive_write_set_compression_xz(?*struct_archive) c_int;
pub extern fn archive_write_add_filter(?*struct_archive, filter_code: c_int) c_int;
pub extern fn archive_write_add_filter_by_name(?*struct_archive, name: [*c]const u8) c_int;
pub extern fn archive_write_add_filter_b64encode(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_bzip2(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_compress(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_grzip(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_gzip(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_lrzip(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_lz4(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_lzip(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_lzma(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_lzop(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_none(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_program(?*struct_archive, cmd: [*c]const u8) c_int;
pub extern fn archive_write_add_filter_uuencode(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_xz(?*struct_archive) c_int;
pub extern fn archive_write_add_filter_zstd(?*struct_archive) c_int;
pub extern fn archive_write_set_format(?*struct_archive, format_code: c_int) c_int;
pub extern fn archive_write_set_format_by_name(?*struct_archive, name: [*c]const u8) c_int;
pub extern fn archive_write_set_format_7zip(?*struct_archive) c_int;
pub extern fn archive_write_set_format_ar_bsd(?*struct_archive) c_int;
pub extern fn archive_write_set_format_ar_svr4(?*struct_archive) c_int;
pub extern fn archive_write_set_format_cpio(?*struct_archive) c_int;
pub extern fn archive_write_set_format_cpio_bin(?*struct_archive) c_int;
pub extern fn archive_write_set_format_cpio_newc(?*struct_archive) c_int;
pub extern fn archive_write_set_format_cpio_odc(?*struct_archive) c_int;
pub extern fn archive_write_set_format_cpio_pwb(?*struct_archive) c_int;
pub extern fn archive_write_set_format_gnutar(?*struct_archive) c_int;
pub extern fn archive_write_set_format_iso9660(?*struct_archive) c_int;
pub extern fn archive_write_set_format_mtree(?*struct_archive) c_int;
pub extern fn archive_write_set_format_mtree_classic(?*struct_archive) c_int;
pub extern fn archive_write_set_format_pax(?*struct_archive) c_int;
pub extern fn archive_write_set_format_pax_restricted(?*struct_archive) c_int;
pub extern fn archive_write_set_format_raw(?*struct_archive) c_int;
pub extern fn archive_write_set_format_shar(?*struct_archive) c_int;
pub extern fn archive_write_set_format_shar_dump(?*struct_archive) c_int;
pub extern fn archive_write_set_format_ustar(?*struct_archive) c_int;
pub extern fn archive_write_set_format_v7tar(?*struct_archive) c_int;
pub extern fn archive_write_set_format_warc(?*struct_archive) c_int;
pub extern fn archive_write_set_format_xar(?*struct_archive) c_int;
pub extern fn archive_write_set_format_zip(?*struct_archive) c_int;
pub extern fn archive_write_set_format_filter_by_ext(a: ?*struct_archive, filename: [*c]const u8) c_int;
pub extern fn archive_write_set_format_filter_by_ext_def(a: ?*struct_archive, filename: [*c]const u8, def_ext: [*c]const u8) c_int;
pub extern fn archive_write_zip_set_compression_deflate(?*struct_archive) c_int;
pub extern fn archive_write_zip_set_compression_store(?*struct_archive) c_int;
pub extern fn archive_write_zip_set_compression_lzma(?*struct_archive) c_int;
pub extern fn archive_write_zip_set_compression_xz(?*struct_archive) c_int;
pub extern fn archive_write_zip_set_compression_bzip2(?*struct_archive) c_int;
pub extern fn archive_write_zip_set_compression_zstd(?*struct_archive) c_int;
pub extern fn archive_write_open(?*struct_archive, ?*anyopaque, ?*const archive_open_callback, ?*const archive_write_callback, ?*const archive_close_callback) c_int;
pub extern fn archive_write_open2(?*struct_archive, ?*anyopaque, ?*const archive_open_callback, ?*const archive_write_callback, ?*const archive_close_callback, ?*const archive_free_callback) c_int;
pub extern fn archive_write_open_fd(?*struct_archive, _fd: c_int) c_int;
pub extern fn archive_write_open_filename(?*struct_archive, _file: [*c]const u8) c_int;
pub extern fn archive_write_open_filename_w(?*struct_archive, _file: [*c]const wchar_t) c_int;
pub extern fn archive_write_open_file(?*struct_archive, _file: [*c]const u8) c_int;
pub extern fn archive_write_open_FILE(?*struct_archive, ?*FILE) c_int;
pub extern fn archive_write_open_memory(?*struct_archive, _buffer: ?*anyopaque, _buffSize: usize, _used: [*c]usize) c_int;
pub extern fn archive_write_header(?*struct_archive, ?*struct_archive_entry) c_int;
pub extern fn archive_write_data(?*struct_archive, ?*const anyopaque, usize) la_ssize_t;
pub extern fn archive_write_data_block(?*struct_archive, ?*const anyopaque, usize, la_int64_t) la_ssize_t;
pub extern fn archive_write_finish_entry(?*struct_archive) c_int;
pub extern fn archive_write_close(?*struct_archive) c_int;
pub extern fn archive_write_fail(?*struct_archive) c_int;
pub extern fn archive_write_free(?*struct_archive) c_int;
pub extern fn archive_write_finish(?*struct_archive) c_int;
pub extern fn archive_write_set_format_option(_a: ?*struct_archive, m: [*c]const u8, o: [*c]const u8, v: [*c]const u8) c_int;
pub extern fn archive_write_set_filter_option(_a: ?*struct_archive, m: [*c]const u8, o: [*c]const u8, v: [*c]const u8) c_int;
pub extern fn archive_write_set_option(_a: ?*struct_archive, m: [*c]const u8, o: [*c]const u8, v: [*c]const u8) c_int;
pub extern fn archive_write_set_options(_a: ?*struct_archive, opts: [*c]const u8) c_int;
pub extern fn archive_write_set_passphrase(_a: ?*struct_archive, p: [*c]const u8) c_int;
pub extern fn archive_write_set_passphrase_callback(?*struct_archive, client_data: ?*anyopaque, ?*const archive_passphrase_callback) c_int;
pub extern fn archive_write_disk_new() ?*struct_archive;
pub extern fn archive_write_disk_set_skip_file(?*struct_archive, la_int64_t, la_int64_t) c_int;
pub extern fn archive_write_disk_set_options(?*struct_archive, flags: c_int) c_int;
pub extern fn archive_write_disk_set_standard_lookup(?*struct_archive) c_int;
pub extern fn archive_write_disk_set_group_lookup(?*struct_archive, ?*anyopaque, ?*const fn (?*anyopaque, [*c]const u8, la_int64_t) callconv(.c) la_int64_t, ?*const fn (?*anyopaque) callconv(.c) void) c_int;
pub extern fn archive_write_disk_set_user_lookup(?*struct_archive, ?*anyopaque, ?*const fn (?*anyopaque, [*c]const u8, la_int64_t) callconv(.c) la_int64_t, ?*const fn (?*anyopaque) callconv(.c) void) c_int;
pub extern fn archive_write_disk_gid(?*struct_archive, [*c]const u8, la_int64_t) la_int64_t;
pub extern fn archive_write_disk_uid(?*struct_archive, [*c]const u8, la_int64_t) la_int64_t;
pub extern fn archive_read_disk_new() ?*struct_archive;
pub extern fn archive_read_disk_set_symlink_logical(?*struct_archive) c_int;
pub extern fn archive_read_disk_set_symlink_physical(?*struct_archive) c_int;
pub extern fn archive_read_disk_set_symlink_hybrid(?*struct_archive) c_int;
pub extern fn archive_read_disk_entry_from_file(?*struct_archive, ?*struct_archive_entry, c_int, [*c]const struct_stat) c_int;
pub extern fn archive_read_disk_gname(?*struct_archive, la_int64_t) [*c]const u8;
pub extern fn archive_read_disk_uname(?*struct_archive, la_int64_t) [*c]const u8;
pub extern fn archive_read_disk_set_standard_lookup(?*struct_archive) c_int;
pub extern fn archive_read_disk_set_gname_lookup(?*struct_archive, ?*anyopaque, ?*const fn (?*anyopaque, la_int64_t) callconv(.c) [*c]const u8, ?*const fn (?*anyopaque) callconv(.c) void) c_int;
pub extern fn archive_read_disk_set_uname_lookup(?*struct_archive, ?*anyopaque, ?*const fn (?*anyopaque, la_int64_t) callconv(.c) [*c]const u8, ?*const fn (?*anyopaque) callconv(.c) void) c_int;
pub extern fn archive_read_disk_open(?*struct_archive, [*c]const u8) c_int;
pub extern fn archive_read_disk_open_w(?*struct_archive, [*c]const wchar_t) c_int;
pub extern fn archive_read_disk_descend(?*struct_archive) c_int;
pub extern fn archive_read_disk_can_descend(?*struct_archive) c_int;
pub extern fn archive_read_disk_current_filesystem(?*struct_archive) c_int;
pub extern fn archive_read_disk_current_filesystem_is_synthetic(?*struct_archive) c_int;
pub extern fn archive_read_disk_current_filesystem_is_remote(?*struct_archive) c_int;
pub extern fn archive_read_disk_set_atime_restored(?*struct_archive) c_int;
pub extern fn archive_read_disk_set_behavior(?*struct_archive, flags: c_int) c_int;
pub extern fn archive_read_disk_set_matching(?*struct_archive, _matching: ?*struct_archive, _excluded_func: ?*const fn (?*struct_archive, ?*anyopaque, ?*struct_archive_entry) callconv(.c) void, _client_data: ?*anyopaque) c_int;
pub extern fn archive_read_disk_set_metadata_filter_callback(?*struct_archive, _metadata_filter_func: ?*const fn (?*struct_archive, ?*anyopaque, ?*struct_archive_entry) callconv(.c) c_int, _client_data: ?*anyopaque) c_int;
pub extern fn archive_free(?*struct_archive) c_int;
pub extern fn archive_filter_count(?*struct_archive) c_int;
pub extern fn archive_filter_bytes(?*struct_archive, c_int) la_int64_t;
pub extern fn archive_filter_code(?*struct_archive, c_int) c_int;
pub extern fn archive_filter_name(?*struct_archive, c_int) [*c]const u8;
pub extern fn archive_position_compressed(?*struct_archive) la_int64_t;
pub extern fn archive_position_uncompressed(?*struct_archive) la_int64_t;
pub extern fn archive_compression_name(?*struct_archive) [*c]const u8;
pub extern fn archive_compression(?*struct_archive) c_int;
pub extern fn archive_parse_date(now: time_t, datestr: [*c]const u8) time_t;
pub extern fn archive_errno(?*struct_archive) c_int;
pub extern fn archive_error_string(?*struct_archive) [*c]const u8;
pub extern fn archive_format_name(?*struct_archive) [*c]const u8;
pub extern fn archive_format(?*struct_archive) c_int;
pub extern fn archive_clear_error(?*struct_archive) void;
pub extern fn archive_set_error(?*struct_archive, _err: c_int, fmt: [*c]const u8, ...) void;
pub extern fn archive_copy_error(dest: ?*struct_archive, src: ?*struct_archive) void;
pub extern fn archive_file_count(?*struct_archive) c_int;
pub extern fn archive_match_new() ?*struct_archive;
pub extern fn archive_match_free(?*struct_archive) c_int;
pub extern fn archive_match_excluded(?*struct_archive, ?*struct_archive_entry) c_int;
pub extern fn archive_match_path_excluded(?*struct_archive, ?*struct_archive_entry) c_int;
pub extern fn archive_match_set_inclusion_recursion(?*struct_archive, c_int) c_int;
pub extern fn archive_match_exclude_pattern(?*struct_archive, [*c]const u8) c_int;
pub extern fn archive_match_exclude_pattern_w(?*struct_archive, [*c]const wchar_t) c_int;
pub extern fn archive_match_exclude_pattern_from_file(?*struct_archive, [*c]const u8, _nullSeparator: c_int) c_int;
pub extern fn archive_match_exclude_pattern_from_file_w(?*struct_archive, [*c]const wchar_t, _nullSeparator: c_int) c_int;
pub extern fn archive_match_include_pattern(?*struct_archive, [*c]const u8) c_int;
pub extern fn archive_match_include_pattern_w(?*struct_archive, [*c]const wchar_t) c_int;
pub extern fn archive_match_include_pattern_from_file(?*struct_archive, [*c]const u8, _nullSeparator: c_int) c_int;
pub extern fn archive_match_include_pattern_from_file_w(?*struct_archive, [*c]const wchar_t, _nullSeparator: c_int) c_int;
pub extern fn archive_match_path_unmatched_inclusions(?*struct_archive) c_int;
pub extern fn archive_match_path_unmatched_inclusions_next(?*struct_archive, [*c][*c]const u8) c_int;
pub extern fn archive_match_path_unmatched_inclusions_next_w(?*struct_archive, [*c][*c]const wchar_t) c_int;
pub extern fn archive_match_time_excluded(?*struct_archive, ?*struct_archive_entry) c_int;
pub extern fn archive_match_include_time(?*struct_archive, _flag: c_int, _sec: time_t, _nsec: c_long) c_int;
pub extern fn archive_match_include_date(?*struct_archive, _flag: c_int, _datestr: [*c]const u8) c_int;
pub extern fn archive_match_include_date_w(?*struct_archive, _flag: c_int, _datestr: [*c]const wchar_t) c_int;
pub extern fn archive_match_include_file_time(?*struct_archive, _flag: c_int, _pathname: [*c]const u8) c_int;
pub extern fn archive_match_include_file_time_w(?*struct_archive, _flag: c_int, _pathname: [*c]const wchar_t) c_int;
pub extern fn archive_match_exclude_entry(?*struct_archive, _flag: c_int, ?*struct_archive_entry) c_int;
pub extern fn archive_match_owner_excluded(?*struct_archive, ?*struct_archive_entry) c_int;
pub extern fn archive_match_include_uid(?*struct_archive, la_int64_t) c_int;
pub extern fn archive_match_include_gid(?*struct_archive, la_int64_t) c_int;
pub extern fn archive_match_include_uname(?*struct_archive, [*c]const u8) c_int;
pub extern fn archive_match_include_uname_w(?*struct_archive, [*c]const wchar_t) c_int;
pub extern fn archive_match_include_gname(?*struct_archive, [*c]const u8) c_int;
pub extern fn archive_match_include_gname_w(?*struct_archive, [*c]const wchar_t) c_int;
pub extern fn archive_utility_string_sort([*c][*c]u8) c_int;
pub extern fn archive_entry_clear(?*struct_archive_entry) ?*struct_archive_entry;
pub extern fn archive_entry_clone(?*struct_archive_entry) ?*struct_archive_entry;
pub extern fn archive_entry_free(?*struct_archive_entry) void;
pub extern fn archive_entry_new() ?*struct_archive_entry;
pub extern fn archive_entry_new2(?*struct_archive) ?*struct_archive_entry;
pub extern fn archive_entry_atime(?*struct_archive_entry) time_t;
pub extern fn archive_entry_atime_nsec(?*struct_archive_entry) c_long;
pub extern fn archive_entry_atime_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_birthtime(?*struct_archive_entry) time_t;
pub extern fn archive_entry_birthtime_nsec(?*struct_archive_entry) c_long;
pub extern fn archive_entry_birthtime_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_ctime(?*struct_archive_entry) time_t;
pub extern fn archive_entry_ctime_nsec(?*struct_archive_entry) c_long;
pub extern fn archive_entry_ctime_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_dev(?*struct_archive_entry) dev_t;
pub extern fn archive_entry_dev_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_devmajor(?*struct_archive_entry) dev_t;
pub extern fn archive_entry_devminor(?*struct_archive_entry) dev_t;
pub extern fn archive_entry_filetype(?*struct_archive_entry) mode_t;
pub extern fn archive_entry_filetype_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_fflags(?*struct_archive_entry, [*c]c_ulong, [*c]c_ulong) void;
pub extern fn archive_entry_fflags_text(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_gid(?*struct_archive_entry) la_int64_t;
pub extern fn archive_entry_gid_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_gname(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_gname_utf8(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_gname_w(?*struct_archive_entry) [*c]const wchar_t;
pub extern fn archive_entry_set_link_to_hardlink(?*struct_archive_entry) void;
pub extern fn archive_entry_hardlink(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_hardlink_utf8(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_hardlink_w(?*struct_archive_entry) [*c]const wchar_t;
pub extern fn archive_entry_hardlink_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_ino(?*struct_archive_entry) la_int64_t;
pub extern fn archive_entry_ino64(?*struct_archive_entry) la_int64_t;
pub extern fn archive_entry_ino_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_mode(?*struct_archive_entry) mode_t;
pub extern fn archive_entry_mtime(?*struct_archive_entry) time_t;
pub extern fn archive_entry_mtime_nsec(?*struct_archive_entry) c_long;
pub extern fn archive_entry_mtime_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_nlink(?*struct_archive_entry) c_uint;
pub extern fn archive_entry_pathname(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_pathname_utf8(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_pathname_w(?*struct_archive_entry) [*c]const wchar_t;
pub extern fn archive_entry_perm(?*struct_archive_entry) mode_t;
pub extern fn archive_entry_perm_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_rdev_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_rdev(?*struct_archive_entry) dev_t;
pub extern fn archive_entry_rdevmajor(?*struct_archive_entry) dev_t;
pub extern fn archive_entry_rdevminor(?*struct_archive_entry) dev_t;
pub extern fn archive_entry_sourcepath(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_sourcepath_w(?*struct_archive_entry) [*c]const wchar_t;
pub extern fn archive_entry_size(?*struct_archive_entry) la_int64_t;
pub extern fn archive_entry_size_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_strmode(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_set_link_to_symlink(?*struct_archive_entry) void;
pub extern fn archive_entry_symlink(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_symlink_utf8(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_symlink_type(?*struct_archive_entry) c_int;
pub extern fn archive_entry_symlink_w(?*struct_archive_entry) [*c]const wchar_t;
pub extern fn archive_entry_uid(?*struct_archive_entry) la_int64_t;
pub extern fn archive_entry_uid_is_set(?*struct_archive_entry) c_int;
pub extern fn archive_entry_uname(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_uname_utf8(?*struct_archive_entry) [*c]const u8;
pub extern fn archive_entry_uname_w(?*struct_archive_entry) [*c]const wchar_t;
pub extern fn archive_entry_is_data_encrypted(?*struct_archive_entry) c_int;
pub extern fn archive_entry_is_metadata_encrypted(?*struct_archive_entry) c_int;
pub extern fn archive_entry_is_encrypted(?*struct_archive_entry) c_int;
pub extern fn archive_entry_set_atime(?*struct_archive_entry, time_t, c_long) void;
pub extern fn archive_entry_unset_atime(?*struct_archive_entry) void;
pub extern fn archive_entry_set_birthtime(?*struct_archive_entry, time_t, c_long) void;
pub extern fn archive_entry_unset_birthtime(?*struct_archive_entry) void;
pub extern fn archive_entry_set_ctime(?*struct_archive_entry, time_t, c_long) void;
pub extern fn archive_entry_unset_ctime(?*struct_archive_entry) void;
pub extern fn archive_entry_set_dev(?*struct_archive_entry, dev_t) void;
pub extern fn archive_entry_set_devmajor(?*struct_archive_entry, dev_t) void;
pub extern fn archive_entry_set_devminor(?*struct_archive_entry, dev_t) void;
pub extern fn archive_entry_set_filetype(?*struct_archive_entry, c_uint) void;
pub extern fn archive_entry_set_fflags(?*struct_archive_entry, c_ulong, c_ulong) void;
pub extern fn archive_entry_copy_fflags_text(?*struct_archive_entry, [*c]const u8) [*c]const u8;
pub extern fn archive_entry_copy_fflags_text_len(?*struct_archive_entry, [*c]const u8, usize) [*c]const u8;
pub extern fn archive_entry_copy_fflags_text_w(?*struct_archive_entry, [*c]const wchar_t) [*c]const wchar_t;
pub extern fn archive_entry_set_gid(?*struct_archive_entry, la_int64_t) void;
pub extern fn archive_entry_set_gname(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_set_gname_utf8(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_gname(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_gname_w(?*struct_archive_entry, [*c]const wchar_t) void;
pub extern fn archive_entry_update_gname_utf8(?*struct_archive_entry, [*c]const u8) c_int;
pub extern fn archive_entry_set_hardlink(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_set_hardlink_utf8(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_hardlink(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_hardlink_w(?*struct_archive_entry, [*c]const wchar_t) void;
pub extern fn archive_entry_update_hardlink_utf8(?*struct_archive_entry, [*c]const u8) c_int;
pub extern fn archive_entry_set_ino(?*struct_archive_entry, la_int64_t) void;
pub extern fn archive_entry_set_ino64(?*struct_archive_entry, la_int64_t) void;
pub extern fn archive_entry_set_link(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_set_link_utf8(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_link(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_link_w(?*struct_archive_entry, [*c]const wchar_t) void;
pub extern fn archive_entry_update_link_utf8(?*struct_archive_entry, [*c]const u8) c_int;
pub extern fn archive_entry_set_mode(?*struct_archive_entry, mode_t) void;
pub extern fn archive_entry_set_mtime(?*struct_archive_entry, time_t, c_long) void;
pub extern fn archive_entry_unset_mtime(?*struct_archive_entry) void;
pub extern fn archive_entry_set_nlink(?*struct_archive_entry, c_uint) void;
pub extern fn archive_entry_set_pathname(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_set_pathname_utf8(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_pathname(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_pathname_w(?*struct_archive_entry, [*c]const wchar_t) void;
pub extern fn archive_entry_update_pathname_utf8(?*struct_archive_entry, [*c]const u8) c_int;
pub extern fn archive_entry_set_perm(?*struct_archive_entry, mode_t) void;
pub extern fn archive_entry_set_rdev(?*struct_archive_entry, dev_t) void;
pub extern fn archive_entry_set_rdevmajor(?*struct_archive_entry, dev_t) void;
pub extern fn archive_entry_set_rdevminor(?*struct_archive_entry, dev_t) void;
pub extern fn archive_entry_set_size(?*struct_archive_entry, la_int64_t) void;
pub extern fn archive_entry_unset_size(?*struct_archive_entry) void;
pub extern fn archive_entry_copy_sourcepath(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_sourcepath_w(?*struct_archive_entry, [*c]const wchar_t) void;
pub extern fn archive_entry_set_symlink(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_set_symlink_type(?*struct_archive_entry, c_int) void;
pub extern fn archive_entry_set_symlink_utf8(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_symlink(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_symlink_w(?*struct_archive_entry, [*c]const wchar_t) void;
pub extern fn archive_entry_update_symlink_utf8(?*struct_archive_entry, [*c]const u8) c_int;
pub extern fn archive_entry_set_uid(?*struct_archive_entry, la_int64_t) void;
pub extern fn archive_entry_set_uname(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_set_uname_utf8(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_uname(?*struct_archive_entry, [*c]const u8) void;
pub extern fn archive_entry_copy_uname_w(?*struct_archive_entry, [*c]const wchar_t) void;
pub extern fn archive_entry_update_uname_utf8(?*struct_archive_entry, [*c]const u8) c_int;
pub extern fn archive_entry_set_is_data_encrypted(?*struct_archive_entry, is_encrypted: u8) void;
pub extern fn archive_entry_set_is_metadata_encrypted(?*struct_archive_entry, is_encrypted: u8) void;
pub extern fn archive_entry_stat(?*struct_archive_entry) [*c]const struct_stat;
pub extern fn archive_entry_copy_stat(?*struct_archive_entry, [*c]const struct_stat) void;
pub extern fn archive_entry_mac_metadata(?*struct_archive_entry, [*c]usize) ?*const anyopaque;
pub extern fn archive_entry_copy_mac_metadata(?*struct_archive_entry, ?*const anyopaque, usize) void;
pub extern fn archive_entry_digest(?*struct_archive_entry, c_int) [*c]const u8;
pub extern fn archive_entry_set_digest(?*struct_archive_entry, c_int, [*c]const u8) c_int;
pub extern fn archive_entry_acl_clear(?*struct_archive_entry) void;
pub extern fn archive_entry_acl_add_entry(?*struct_archive_entry, c_int, c_int, c_int, c_int, [*c]const u8) c_int;
pub extern fn archive_entry_acl_add_entry_w(?*struct_archive_entry, c_int, c_int, c_int, c_int, [*c]const wchar_t) c_int;
pub extern fn archive_entry_acl_reset(?*struct_archive_entry, c_int) c_int;
pub extern fn archive_entry_acl_next(?*struct_archive_entry, c_int, [*c]c_int, [*c]c_int, [*c]c_int, [*c]c_int, [*c][*c]const u8) c_int;
pub extern fn archive_entry_acl_to_text_w(?*struct_archive_entry, [*c]la_ssize_t, c_int) [*c]wchar_t;
pub extern fn archive_entry_acl_to_text(?*struct_archive_entry, [*c]la_ssize_t, c_int) [*c]u8;
pub extern fn archive_entry_acl_from_text_w(?*struct_archive_entry, [*c]const wchar_t, c_int) c_int;
pub extern fn archive_entry_acl_from_text(?*struct_archive_entry, [*c]const u8, c_int) c_int;
pub extern fn archive_entry_acl_text_w(?*struct_archive_entry, c_int) [*c]const wchar_t;
pub extern fn archive_entry_acl_text(?*struct_archive_entry, c_int) [*c]const u8;
pub extern fn archive_entry_acl_types(?*struct_archive_entry) c_int;
pub extern fn archive_entry_acl_count(?*struct_archive_entry, c_int) c_int;
pub const struct_archive_acl = opaque {};
pub extern fn archive_entry_acl(?*struct_archive_entry) ?*struct_archive_acl;
pub extern fn archive_entry_xattr_clear(?*struct_archive_entry) void;
pub extern fn archive_entry_xattr_add_entry(?*struct_archive_entry, [*c]const u8, ?*const anyopaque, usize) void;
pub extern fn archive_entry_xattr_count(?*struct_archive_entry) c_int;
pub extern fn archive_entry_xattr_reset(?*struct_archive_entry) c_int;
pub extern fn archive_entry_xattr_next(?*struct_archive_entry, [*c][*c]const u8, [*c]?*const anyopaque, [*c]usize) c_int;
pub extern fn archive_entry_sparse_clear(?*struct_archive_entry) void;
pub extern fn archive_entry_sparse_add_entry(?*struct_archive_entry, la_int64_t, la_int64_t) void;
pub extern fn archive_entry_sparse_count(?*struct_archive_entry) c_int;
pub extern fn archive_entry_sparse_reset(?*struct_archive_entry) c_int;
pub extern fn archive_entry_sparse_next(?*struct_archive_entry, [*c]la_int64_t, [*c]la_int64_t) c_int;
pub const struct_archive_entry_linkresolver = opaque {
    pub const archive_entry_linkresolver_set_strategy = __root.archive_entry_linkresolver_set_strategy;
    pub const archive_entry_linkresolver_free = __root.archive_entry_linkresolver_free;
    pub const archive_entry_linkify = __root.archive_entry_linkify;
    pub const archive_entry_partial_links = __root.archive_entry_partial_links;
    pub const set_strategy = __root.archive_entry_linkresolver_set_strategy;
    pub const linkify = __root.archive_entry_linkify;
    pub const links = __root.archive_entry_partial_links;
};
pub extern fn archive_entry_linkresolver_new() ?*struct_archive_entry_linkresolver;
pub extern fn archive_entry_linkresolver_set_strategy(?*struct_archive_entry_linkresolver, c_int) void;
pub extern fn archive_entry_linkresolver_free(?*struct_archive_entry_linkresolver) void;
pub extern fn archive_entry_linkify(?*struct_archive_entry_linkresolver, [*c]?*struct_archive_entry, [*c]?*struct_archive_entry) void;
pub extern fn archive_entry_partial_links(res: ?*struct_archive_entry_linkresolver, links: [*c]c_uint) ?*struct_archive_entry;
pub const div_t = extern struct {
    quot: c_int = 0,
    rem: c_int = 0,
};
pub const ldiv_t = extern struct {
    quot: c_long = 0,
    rem: c_long = 0,
};
pub const lldiv_t = extern struct {
    quot: c_longlong = 0,
    rem: c_longlong = 0,
};
pub extern fn __ctype_get_mb_cur_max() usize;
pub extern fn atof(__nptr: [*c]const u8) f64;
pub extern fn atoi(__nptr: [*c]const u8) c_int;
pub extern fn atol(__nptr: [*c]const u8) c_long;
pub extern fn atoll(__nptr: [*c]const u8) c_longlong;
pub extern fn strtod(noalias __nptr: [*c]const u8, noalias __endptr: [*c][*c]u8) f64;
pub extern fn strtof(noalias __nptr: [*c]const u8, noalias __endptr: [*c][*c]u8) f32;
pub extern fn strtold(noalias __nptr: [*c]const u8, noalias __endptr: [*c][*c]u8) c_longdouble;
pub extern fn strtol(noalias __nptr: [*c]const u8, noalias __endptr: [*c][*c]u8, __base: c_int) c_long;
pub extern fn strtoul(noalias __nptr: [*c]const u8, noalias __endptr: [*c][*c]u8, __base: c_int) c_ulong;
pub extern fn strtoq(noalias __nptr: [*c]const u8, noalias __endptr: [*c][*c]u8, __base: c_int) c_longlong;
pub extern fn strtouq(noalias __nptr: [*c]const u8, noalias __endptr: [*c][*c]u8, __base: c_int) c_ulonglong;
pub extern fn strtoll(noalias __nptr: [*c]const u8, noalias __endptr: [*c][*c]u8, __base: c_int) c_longlong;
pub extern fn strtoull(noalias __nptr: [*c]const u8, noalias __endptr: [*c][*c]u8, __base: c_int) c_ulonglong;
pub extern fn l64a(__n: c_long) [*c]u8;
pub extern fn a64l(__s: [*c]const u8) c_long;
pub extern fn random() c_long;
pub extern fn srandom(__seed: c_uint) void;
pub extern fn initstate(__seed: c_uint, __statebuf: [*c]u8, __statelen: usize) [*c]u8;
pub extern fn setstate(__statebuf: [*c]u8) [*c]u8;
pub const struct_random_data = extern struct {
    fptr: [*c]i32 = null,
    rptr: [*c]i32 = null,
    state: [*c]i32 = null,
    rand_type: c_int = 0,
    rand_deg: c_int = 0,
    rand_sep: c_int = 0,
    end_ptr: [*c]i32 = null,
    pub const random_r = __root.random_r;
    pub const r = __root.random_r;
};
pub extern fn random_r(noalias __buf: [*c]struct_random_data, noalias __result: [*c]i32) c_int;
pub extern fn srandom_r(__seed: c_uint, __buf: [*c]struct_random_data) c_int;
pub extern fn initstate_r(__seed: c_uint, noalias __statebuf: [*c]u8, __statelen: usize, noalias __buf: [*c]struct_random_data) c_int;
pub extern fn setstate_r(noalias __statebuf: [*c]u8, noalias __buf: [*c]struct_random_data) c_int;
pub extern fn rand() c_int;
pub extern fn srand(__seed: c_uint) void;
pub extern fn rand_r(__seed: [*c]c_uint) c_int;
pub extern fn drand48() f64;
pub extern fn erand48(__xsubi: [*c]c_ushort) f64;
pub extern fn lrand48() c_long;
pub extern fn nrand48(__xsubi: [*c]c_ushort) c_long;
pub extern fn mrand48() c_long;
pub extern fn jrand48(__xsubi: [*c]c_ushort) c_long;
pub extern fn srand48(__seedval: c_long) void;
pub extern fn seed48(__seed16v: [*c]c_ushort) [*c]c_ushort;
pub extern fn lcong48(__param: [*c]c_ushort) void;
pub const struct_drand48_data = extern struct {
    __x: [3]c_ushort = @import("std").mem.zeroes([3]c_ushort),
    __old_x: [3]c_ushort = @import("std").mem.zeroes([3]c_ushort),
    __c: c_ushort = 0,
    __init: c_ushort = 0,
    __a: c_ulonglong = 0,
    pub const drand48_r = __root.drand48_r;
    pub const lrand48_r = __root.lrand48_r;
    pub const mrand48_r = __root.mrand48_r;
    pub const r = __root.drand48_r;
};
pub extern fn drand48_r(noalias __buffer: [*c]struct_drand48_data, noalias __result: [*c]f64) c_int;
pub extern fn erand48_r(__xsubi: [*c]c_ushort, noalias __buffer: [*c]struct_drand48_data, noalias __result: [*c]f64) c_int;
pub extern fn lrand48_r(noalias __buffer: [*c]struct_drand48_data, noalias __result: [*c]c_long) c_int;
pub extern fn nrand48_r(__xsubi: [*c]c_ushort, noalias __buffer: [*c]struct_drand48_data, noalias __result: [*c]c_long) c_int;
pub extern fn mrand48_r(noalias __buffer: [*c]struct_drand48_data, noalias __result: [*c]c_long) c_int;
pub extern fn jrand48_r(__xsubi: [*c]c_ushort, noalias __buffer: [*c]struct_drand48_data, noalias __result: [*c]c_long) c_int;
pub extern fn srand48_r(__seedval: c_long, __buffer: [*c]struct_drand48_data) c_int;
pub extern fn seed48_r(__seed16v: [*c]c_ushort, __buffer: [*c]struct_drand48_data) c_int;
pub extern fn lcong48_r(__param: [*c]c_ushort, __buffer: [*c]struct_drand48_data) c_int;
pub extern fn arc4random() __uint32_t;
pub extern fn arc4random_buf(__buf: ?*anyopaque, __size: usize) void;
pub extern fn arc4random_uniform(__upper_bound: __uint32_t) __uint32_t;
pub extern fn malloc(__size: usize) ?*anyopaque;
pub extern fn calloc(__nmemb: usize, __size: usize) ?*anyopaque;
pub extern fn realloc(__ptr: ?*anyopaque, __size: usize) ?*anyopaque;
pub extern fn free(__ptr: ?*anyopaque) void;
pub extern fn reallocarray(__ptr: ?*anyopaque, __nmemb: usize, __size: usize) ?*anyopaque;
pub extern fn alloca(__size: usize) ?*anyopaque;
pub extern fn valloc(__size: usize) ?*anyopaque;
pub extern fn posix_memalign(__memptr: [*c]?*anyopaque, __alignment: usize, __size: usize) c_int;
pub extern fn aligned_alloc(__alignment: usize, __size: usize) ?*anyopaque;
pub extern fn abort() noreturn;
pub extern fn atexit(__func: ?*const fn () callconv(.c) void) c_int;
pub extern fn at_quick_exit(__func: ?*const fn () callconv(.c) void) c_int;
pub extern fn on_exit(__func: ?*const fn (__status: c_int, __arg: ?*anyopaque) callconv(.c) void, __arg: ?*anyopaque) c_int;
pub extern fn exit(__status: c_int) noreturn;
pub extern fn quick_exit(__status: c_int) noreturn;
pub extern fn _Exit(__status: c_int) noreturn;
pub extern fn getenv(__name: [*c]const u8) [*c]u8;
pub extern fn putenv(__string: [*c]u8) c_int;
pub extern fn setenv(__name: [*c]const u8, __value: [*c]const u8, __replace: c_int) c_int;
pub extern fn unsetenv(__name: [*c]const u8) c_int;
pub extern fn clearenv() c_int;
pub extern fn mktemp(__template: [*c]u8) [*c]u8;
pub extern fn mkstemp(__template: [*c]u8) c_int;
pub extern fn mkstemps(__template: [*c]u8, __suffixlen: c_int) c_int;
pub extern fn mkdtemp(__template: [*c]u8) [*c]u8;
pub extern fn system(__command: [*c]const u8) c_int;
pub extern fn realpath(noalias __name: [*c]const u8, noalias __resolved: [*c]u8) [*c]u8;
pub const __compar_fn_t = ?*const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;
pub extern fn bsearch(__key: ?*const anyopaque, __base: ?*const anyopaque, __nmemb: usize, __size: usize, __compar: __compar_fn_t) ?*anyopaque;
pub extern fn qsort(__base: ?*anyopaque, __nmemb: usize, __size: usize, __compar: __compar_fn_t) void;
pub extern fn abs(__x: c_int) c_int;
pub extern fn labs(__x: c_long) c_long;
pub extern fn llabs(__x: c_longlong) c_longlong;
pub extern fn div(__numer: c_int, __denom: c_int) div_t;
pub extern fn ldiv(__numer: c_long, __denom: c_long) ldiv_t;
pub extern fn lldiv(__numer: c_longlong, __denom: c_longlong) lldiv_t;
pub extern fn ecvt(__value: f64, __ndigit: c_int, noalias __decpt: [*c]c_int, noalias __sign: [*c]c_int) [*c]u8;
pub extern fn fcvt(__value: f64, __ndigit: c_int, noalias __decpt: [*c]c_int, noalias __sign: [*c]c_int) [*c]u8;
pub extern fn gcvt(__value: f64, __ndigit: c_int, __buf: [*c]u8) [*c]u8;
pub extern fn qecvt(__value: c_longdouble, __ndigit: c_int, noalias __decpt: [*c]c_int, noalias __sign: [*c]c_int) [*c]u8;
pub extern fn qfcvt(__value: c_longdouble, __ndigit: c_int, noalias __decpt: [*c]c_int, noalias __sign: [*c]c_int) [*c]u8;
pub extern fn qgcvt(__value: c_longdouble, __ndigit: c_int, __buf: [*c]u8) [*c]u8;
pub extern fn ecvt_r(__value: f64, __ndigit: c_int, noalias __decpt: [*c]c_int, noalias __sign: [*c]c_int, noalias __buf: [*c]u8, __len: usize) c_int;
pub extern fn fcvt_r(__value: f64, __ndigit: c_int, noalias __decpt: [*c]c_int, noalias __sign: [*c]c_int, noalias __buf: [*c]u8, __len: usize) c_int;
pub extern fn qecvt_r(__value: c_longdouble, __ndigit: c_int, noalias __decpt: [*c]c_int, noalias __sign: [*c]c_int, noalias __buf: [*c]u8, __len: usize) c_int;
pub extern fn qfcvt_r(__value: c_longdouble, __ndigit: c_int, noalias __decpt: [*c]c_int, noalias __sign: [*c]c_int, noalias __buf: [*c]u8, __len: usize) c_int;
pub extern fn mblen(__s: [*c]const u8, __n: usize) c_int;
pub extern fn mbtowc(noalias __pwc: [*c]wchar_t, noalias __s: [*c]const u8, __n: usize) c_int;
pub extern fn wctomb(__s: [*c]u8, __wchar: wchar_t) c_int;
pub extern fn mbstowcs(noalias __pwcs: [*c]wchar_t, noalias __s: [*c]const u8, __n: usize) usize;
pub extern fn wcstombs(noalias __s: [*c]u8, noalias __pwcs: [*c]const wchar_t, __n: usize) usize;
pub extern fn rpmatch(__response: [*c]const u8) c_int;
pub extern fn getsubopt(noalias __optionp: [*c][*c]u8, noalias __tokens: [*c]const [*c]u8, noalias __valuep: [*c][*c]u8) c_int;
pub extern fn getloadavg(__loadavg: [*c]f64, __nelem: c_int) c_int;
pub const struct__alpm_list_t = extern struct {
    data: ?*anyopaque = null,
    prev: [*c]struct__alpm_list_t = null,
    next: [*c]struct__alpm_list_t = null,
    pub const alpm_list_free = __root.alpm_list_free;
    pub const alpm_list_free_inner = __root.alpm_list_free_inner;
    pub const alpm_list_add = __root.alpm_list_add;
    pub const alpm_list_add_sorted = __root.alpm_list_add_sorted;
    pub const alpm_list_join = __root.alpm_list_join;
    pub const alpm_list_mmerge = __root.alpm_list_mmerge;
    pub const alpm_list_msort = __root.alpm_list_msort;
    pub const alpm_list_remove_item = __root.alpm_list_remove_item;
    pub const alpm_list_remove = __root.alpm_list_remove;
    pub const alpm_list_remove_str = __root.alpm_list_remove_str;
    pub const alpm_list_remove_dupes = __root.alpm_list_remove_dupes;
    pub const alpm_list_strdup = __root.alpm_list_strdup;
    pub const alpm_list_copy = __root.alpm_list_copy;
    pub const alpm_list_copy_data = __root.alpm_list_copy_data;
    pub const alpm_list_reverse = __root.alpm_list_reverse;
    pub const alpm_list_nth = __root.alpm_list_nth;
    pub const alpm_list_next = __root.alpm_list_next;
    pub const alpm_list_previous = __root.alpm_list_previous;
    pub const alpm_list_last = __root.alpm_list_last;
    pub const alpm_list_count = __root.alpm_list_count;
    pub const alpm_list_find = __root.alpm_list_find;
    pub const alpm_list_find_ptr = __root.alpm_list_find_ptr;
    pub const alpm_list_find_str = __root.alpm_list_find_str;
    pub const alpm_list_cmp_unsorted = __root.alpm_list_cmp_unsorted;
    pub const alpm_list_diff_sorted = __root.alpm_list_diff_sorted;
    pub const alpm_list_diff = __root.alpm_list_diff;
    pub const alpm_list_to_array = __root.alpm_list_to_array;
    pub const alpm_find_group_pkgs = __root.alpm_find_group_pkgs;
    pub const alpm_find_satisfier = __root.alpm_find_satisfier;
    pub const alpm_pkg_find = __root.alpm_pkg_find;
    pub const inner = __root.alpm_list_free_inner;
    pub const add = __root.alpm_list_add;
    pub const sorted = __root.alpm_list_add_sorted;
    pub const join = __root.alpm_list_join;
    pub const mmerge = __root.alpm_list_mmerge;
    pub const msort = __root.alpm_list_msort;
    pub const item = __root.alpm_list_remove_item;
    pub const str = __root.alpm_list_remove_str;
    pub const dupes = __root.alpm_list_remove_dupes;
    pub const strdup = __root.alpm_list_strdup;
    pub const copy = __root.alpm_list_copy;
    pub const reverse = __root.alpm_list_reverse;
    pub const nth = __root.alpm_list_nth;
    pub const previous = __root.alpm_list_previous;
    pub const last = __root.alpm_list_last;
    pub const count = __root.alpm_list_count;
    pub const find = __root.alpm_list_find;
    pub const ptr = __root.alpm_list_find_ptr;
    pub const unsorted = __root.alpm_list_cmp_unsorted;
    pub const diff = __root.alpm_list_diff;
    pub const array = __root.alpm_list_to_array;
    pub const pkgs = __root.alpm_find_group_pkgs;
    pub const satisfier = __root.alpm_find_satisfier;
};
pub const alpm_list_t = struct__alpm_list_t;
pub const alpm_list_fn_free = ?*const fn (item: ?*anyopaque) callconv(.c) void;
pub const alpm_list_fn_cmp = ?*const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int;
pub extern fn alpm_list_free(list: [*c]alpm_list_t) void;
pub extern fn alpm_list_free_inner(list: [*c]alpm_list_t, @"fn": alpm_list_fn_free) void;
pub extern fn alpm_list_add(list: [*c]alpm_list_t, data: ?*anyopaque) [*c]alpm_list_t;
pub extern fn alpm_list_append(list: [*c][*c]alpm_list_t, data: ?*anyopaque) [*c]alpm_list_t;
pub extern fn alpm_list_append_strdup(list: [*c][*c]alpm_list_t, data: [*c]const u8) [*c]alpm_list_t;
pub extern fn alpm_list_add_sorted(list: [*c]alpm_list_t, data: ?*anyopaque, @"fn": alpm_list_fn_cmp) [*c]alpm_list_t;
pub extern fn alpm_list_join(first: [*c]alpm_list_t, second: [*c]alpm_list_t) [*c]alpm_list_t;
pub extern fn alpm_list_mmerge(left: [*c]alpm_list_t, right: [*c]alpm_list_t, @"fn": alpm_list_fn_cmp) [*c]alpm_list_t;
pub extern fn alpm_list_msort(list: [*c]alpm_list_t, n: usize, @"fn": alpm_list_fn_cmp) [*c]alpm_list_t;
pub extern fn alpm_list_remove_item(haystack: [*c]alpm_list_t, item: [*c]alpm_list_t) [*c]alpm_list_t;
pub extern fn alpm_list_remove(haystack: [*c]alpm_list_t, needle: ?*const anyopaque, @"fn": alpm_list_fn_cmp, data: [*c]?*anyopaque) [*c]alpm_list_t;
pub extern fn alpm_list_remove_str(haystack: [*c]alpm_list_t, needle: [*c]const u8, data: [*c][*c]u8) [*c]alpm_list_t;
pub extern fn alpm_list_remove_dupes(list: [*c]const alpm_list_t) [*c]alpm_list_t;
pub extern fn alpm_list_strdup(list: [*c]const alpm_list_t) [*c]alpm_list_t;
pub extern fn alpm_list_copy(list: [*c]const alpm_list_t) [*c]alpm_list_t;
pub extern fn alpm_list_copy_data(list: [*c]const alpm_list_t, size: usize) [*c]alpm_list_t;
pub extern fn alpm_list_reverse(list: [*c]alpm_list_t) [*c]alpm_list_t;
pub extern fn alpm_list_nth(list: [*c]const alpm_list_t, n: usize) [*c]alpm_list_t;
pub extern fn alpm_list_next(list: [*c]const alpm_list_t) [*c]alpm_list_t;
pub extern fn alpm_list_previous(list: [*c]const alpm_list_t) [*c]alpm_list_t;
pub extern fn alpm_list_last(list: [*c]const alpm_list_t) [*c]alpm_list_t;
pub extern fn alpm_list_count(list: [*c]const alpm_list_t) usize;
pub extern fn alpm_list_find(haystack: [*c]const alpm_list_t, needle: ?*const anyopaque, @"fn": alpm_list_fn_cmp) ?*anyopaque;
pub extern fn alpm_list_find_ptr(haystack: [*c]const alpm_list_t, needle: ?*const anyopaque) ?*anyopaque;
pub extern fn alpm_list_find_str(haystack: [*c]const alpm_list_t, needle: [*c]const u8) [*c]u8;
pub extern fn alpm_list_cmp_unsorted(left: [*c]const alpm_list_t, right: [*c]const alpm_list_t, @"fn": alpm_list_fn_cmp) c_int;
pub extern fn alpm_list_diff_sorted(left: [*c]const alpm_list_t, right: [*c]const alpm_list_t, @"fn": alpm_list_fn_cmp, onlyleft: [*c][*c]alpm_list_t, onlyright: [*c][*c]alpm_list_t) void;
pub extern fn alpm_list_diff(lhs: [*c]const alpm_list_t, rhs: [*c]const alpm_list_t, @"fn": alpm_list_fn_cmp) [*c]alpm_list_t;
pub extern fn alpm_list_to_array(list: [*c]const alpm_list_t, n: usize, size: usize) ?*anyopaque;
pub const struct__alpm_handle_t = opaque {
    pub const alpm_errno = __root.alpm_errno;
    pub const alpm_release = __root.alpm_release;
    pub const alpm_extract_keyid = __root.alpm_extract_keyid;
    pub const alpm_checkdeps = __root.alpm_checkdeps;
    pub const alpm_find_dbs_satisfier = __root.alpm_find_dbs_satisfier;
    pub const alpm_checkconflicts = __root.alpm_checkconflicts;
    pub const alpm_get_localdb = __root.alpm_get_localdb;
    pub const alpm_get_syncdbs = __root.alpm_get_syncdbs;
    pub const alpm_register_syncdb = __root.alpm_register_syncdb;
    pub const alpm_unregister_all_syncdbs = __root.alpm_unregister_all_syncdbs;
    pub const alpm_db_update = __root.alpm_db_update;
    pub const alpm_logaction = __root.alpm_logaction;
    pub const alpm_option_get_logcb = __root.alpm_option_get_logcb;
    pub const alpm_option_get_logcb_ctx = __root.alpm_option_get_logcb_ctx;
    pub const alpm_option_set_logcb = __root.alpm_option_set_logcb;
    pub const alpm_option_get_dlcb = __root.alpm_option_get_dlcb;
    pub const alpm_option_get_dlcb_ctx = __root.alpm_option_get_dlcb_ctx;
    pub const alpm_option_set_dlcb = __root.alpm_option_set_dlcb;
    pub const alpm_option_get_fetchcb = __root.alpm_option_get_fetchcb;
    pub const alpm_option_get_fetchcb_ctx = __root.alpm_option_get_fetchcb_ctx;
    pub const alpm_option_set_fetchcb = __root.alpm_option_set_fetchcb;
    pub const alpm_option_get_eventcb = __root.alpm_option_get_eventcb;
    pub const alpm_option_get_eventcb_ctx = __root.alpm_option_get_eventcb_ctx;
    pub const alpm_option_set_eventcb = __root.alpm_option_set_eventcb;
    pub const alpm_option_get_questioncb = __root.alpm_option_get_questioncb;
    pub const alpm_option_get_questioncb_ctx = __root.alpm_option_get_questioncb_ctx;
    pub const alpm_option_set_questioncb = __root.alpm_option_set_questioncb;
    pub const alpm_option_get_progresscb = __root.alpm_option_get_progresscb;
    pub const alpm_option_get_progresscb_ctx = __root.alpm_option_get_progresscb_ctx;
    pub const alpm_option_set_progresscb = __root.alpm_option_set_progresscb;
    pub const alpm_option_get_root = __root.alpm_option_get_root;
    pub const alpm_option_get_dbpath = __root.alpm_option_get_dbpath;
    pub const alpm_option_get_lockfile = __root.alpm_option_get_lockfile;
    pub const alpm_option_get_cachedirs = __root.alpm_option_get_cachedirs;
    pub const alpm_option_set_cachedirs = __root.alpm_option_set_cachedirs;
    pub const alpm_option_add_cachedir = __root.alpm_option_add_cachedir;
    pub const alpm_option_remove_cachedir = __root.alpm_option_remove_cachedir;
    pub const alpm_option_get_hookdirs = __root.alpm_option_get_hookdirs;
    pub const alpm_option_set_hookdirs = __root.alpm_option_set_hookdirs;
    pub const alpm_option_add_hookdir = __root.alpm_option_add_hookdir;
    pub const alpm_option_remove_hookdir = __root.alpm_option_remove_hookdir;
    pub const alpm_option_get_overwrite_files = __root.alpm_option_get_overwrite_files;
    pub const alpm_option_set_overwrite_files = __root.alpm_option_set_overwrite_files;
    pub const alpm_option_add_overwrite_file = __root.alpm_option_add_overwrite_file;
    pub const alpm_option_remove_overwrite_file = __root.alpm_option_remove_overwrite_file;
    pub const alpm_option_get_logfile = __root.alpm_option_get_logfile;
    pub const alpm_option_set_logfile = __root.alpm_option_set_logfile;
    pub const alpm_option_get_gpgdir = __root.alpm_option_get_gpgdir;
    pub const alpm_option_set_gpgdir = __root.alpm_option_set_gpgdir;
    pub const alpm_option_get_sandboxuser = __root.alpm_option_get_sandboxuser;
    pub const alpm_option_set_sandboxuser = __root.alpm_option_set_sandboxuser;
    pub const alpm_option_get_usesyslog = __root.alpm_option_get_usesyslog;
    pub const alpm_option_set_usesyslog = __root.alpm_option_set_usesyslog;
    pub const alpm_option_get_noupgrades = __root.alpm_option_get_noupgrades;
    pub const alpm_option_add_noupgrade = __root.alpm_option_add_noupgrade;
    pub const alpm_option_set_noupgrades = __root.alpm_option_set_noupgrades;
    pub const alpm_option_remove_noupgrade = __root.alpm_option_remove_noupgrade;
    pub const alpm_option_match_noupgrade = __root.alpm_option_match_noupgrade;
    pub const alpm_option_get_noextracts = __root.alpm_option_get_noextracts;
    pub const alpm_option_add_noextract = __root.alpm_option_add_noextract;
    pub const alpm_option_set_noextracts = __root.alpm_option_set_noextracts;
    pub const alpm_option_remove_noextract = __root.alpm_option_remove_noextract;
    pub const alpm_option_match_noextract = __root.alpm_option_match_noextract;
    pub const alpm_option_get_ignorepkgs = __root.alpm_option_get_ignorepkgs;
    pub const alpm_option_add_ignorepkg = __root.alpm_option_add_ignorepkg;
    pub const alpm_option_set_ignorepkgs = __root.alpm_option_set_ignorepkgs;
    pub const alpm_option_remove_ignorepkg = __root.alpm_option_remove_ignorepkg;
    pub const alpm_option_get_ignoregroups = __root.alpm_option_get_ignoregroups;
    pub const alpm_option_add_ignoregroup = __root.alpm_option_add_ignoregroup;
    pub const alpm_option_set_ignoregroups = __root.alpm_option_set_ignoregroups;
    pub const alpm_option_remove_ignoregroup = __root.alpm_option_remove_ignoregroup;
    pub const alpm_option_get_assumeinstalled = __root.alpm_option_get_assumeinstalled;
    pub const alpm_option_add_assumeinstalled = __root.alpm_option_add_assumeinstalled;
    pub const alpm_option_set_assumeinstalled = __root.alpm_option_set_assumeinstalled;
    pub const alpm_option_remove_assumeinstalled = __root.alpm_option_remove_assumeinstalled;
    pub const alpm_option_get_physical_architectures = __root.alpm_option_get_physical_architectures;
    pub const alpm_option_get_architectures = __root.alpm_option_get_architectures;
    pub const alpm_option_add_architecture = __root.alpm_option_add_architecture;
    pub const alpm_option_set_architectures = __root.alpm_option_set_architectures;
    pub const alpm_option_remove_architecture = __root.alpm_option_remove_architecture;
    pub const alpm_option_get_checkspace = __root.alpm_option_get_checkspace;
    pub const alpm_option_set_checkspace = __root.alpm_option_set_checkspace;
    pub const alpm_option_get_dbext = __root.alpm_option_get_dbext;
    pub const alpm_option_set_dbext = __root.alpm_option_set_dbext;
    pub const alpm_option_get_default_siglevel = __root.alpm_option_get_default_siglevel;
    pub const alpm_option_set_default_siglevel = __root.alpm_option_set_default_siglevel;
    pub const alpm_option_get_local_file_siglevel = __root.alpm_option_get_local_file_siglevel;
    pub const alpm_option_set_local_file_siglevel = __root.alpm_option_set_local_file_siglevel;
    pub const alpm_option_get_remote_file_siglevel = __root.alpm_option_get_remote_file_siglevel;
    pub const alpm_option_set_remote_file_siglevel = __root.alpm_option_set_remote_file_siglevel;
    pub const alpm_option_get_disable_dl_timeout = __root.alpm_option_get_disable_dl_timeout;
    pub const alpm_option_set_disable_dl_timeout = __root.alpm_option_set_disable_dl_timeout;
    pub const alpm_option_get_parallel_downloads = __root.alpm_option_get_parallel_downloads;
    pub const alpm_option_set_parallel_downloads = __root.alpm_option_set_parallel_downloads;
    pub const alpm_option_get_disable_sandbox = __root.alpm_option_get_disable_sandbox;
    pub const alpm_option_set_disable_sandbox = __root.alpm_option_set_disable_sandbox;
    pub const alpm_option_get_disable_sandbox_filesystem = __root.alpm_option_get_disable_sandbox_filesystem;
    pub const alpm_option_set_disable_sandbox_filesystem = __root.alpm_option_set_disable_sandbox_filesystem;
    pub const alpm_option_get_disable_sandbox_syscalls = __root.alpm_option_get_disable_sandbox_syscalls;
    pub const alpm_option_set_disable_sandbox_syscalls = __root.alpm_option_set_disable_sandbox_syscalls;
    pub const alpm_option_get_disable_sandbox_network = __root.alpm_option_get_disable_sandbox_network;
    pub const alpm_option_set_disable_sandbox_network = __root.alpm_option_set_disable_sandbox_network;
    pub const alpm_pkg_load = __root.alpm_pkg_load;
    pub const alpm_fetch_pkgurl = __root.alpm_fetch_pkgurl;
    pub const alpm_pkg_should_ignore = __root.alpm_pkg_should_ignore;
    pub const alpm_trans_get_flags = __root.alpm_trans_get_flags;
    pub const alpm_trans_get_add = __root.alpm_trans_get_add;
    pub const alpm_trans_get_remove = __root.alpm_trans_get_remove;
    pub const alpm_trans_init = __root.alpm_trans_init;
    pub const alpm_trans_prepare = __root.alpm_trans_prepare;
    pub const alpm_trans_commit = __root.alpm_trans_commit;
    pub const alpm_trans_interrupt = __root.alpm_trans_interrupt;
    pub const alpm_trans_release = __root.alpm_trans_release;
    pub const alpm_sync_sysupgrade = __root.alpm_sync_sysupgrade;
    pub const alpm_add_pkg = __root.alpm_add_pkg;
    pub const alpm_remove_pkg = __root.alpm_remove_pkg;
    pub const alpm_unlock = __root.alpm_unlock;
    pub const alpm_sandbox_setup_child = __root.alpm_sandbox_setup_child;
    pub const errno = __root.alpm_errno;
    pub const release = __root.alpm_release;
    pub const keyid = __root.alpm_extract_keyid;
    pub const checkdeps = __root.alpm_checkdeps;
    pub const satisfier = __root.alpm_find_dbs_satisfier;
    pub const checkconflicts = __root.alpm_checkconflicts;
    pub const localdb = __root.alpm_get_localdb;
    pub const syncdbs = __root.alpm_get_syncdbs;
    pub const syncdb = __root.alpm_register_syncdb;
    pub const update = __root.alpm_db_update;
    pub const logaction = __root.alpm_logaction;
    pub const logcb = __root.alpm_option_get_logcb;
    pub const ctx = __root.alpm_option_get_logcb_ctx;
    pub const dlcb = __root.alpm_option_get_dlcb;
    pub const fetchcb = __root.alpm_option_get_fetchcb;
    pub const eventcb = __root.alpm_option_get_eventcb;
    pub const questioncb = __root.alpm_option_get_questioncb;
    pub const progresscb = __root.alpm_option_get_progresscb;
    pub const root = __root.alpm_option_get_root;
    pub const dbpath = __root.alpm_option_get_dbpath;
    pub const lockfile = __root.alpm_option_get_lockfile;
    pub const cachedirs = __root.alpm_option_get_cachedirs;
    pub const cachedir = __root.alpm_option_add_cachedir;
    pub const hookdirs = __root.alpm_option_get_hookdirs;
    pub const hookdir = __root.alpm_option_add_hookdir;
    pub const files = __root.alpm_option_get_overwrite_files;
    pub const file = __root.alpm_option_add_overwrite_file;
    pub const logfile = __root.alpm_option_get_logfile;
    pub const gpgdir = __root.alpm_option_get_gpgdir;
    pub const sandboxuser = __root.alpm_option_get_sandboxuser;
    pub const usesyslog = __root.alpm_option_get_usesyslog;
    pub const noupgrades = __root.alpm_option_get_noupgrades;
    pub const noupgrade = __root.alpm_option_add_noupgrade;
    pub const noextracts = __root.alpm_option_get_noextracts;
    pub const noextract = __root.alpm_option_add_noextract;
    pub const ignorepkgs = __root.alpm_option_get_ignorepkgs;
    pub const ignorepkg = __root.alpm_option_add_ignorepkg;
    pub const ignoregroups = __root.alpm_option_get_ignoregroups;
    pub const ignoregroup = __root.alpm_option_add_ignoregroup;
    pub const assumeinstalled = __root.alpm_option_get_assumeinstalled;
    pub const architectures = __root.alpm_option_get_physical_architectures;
    pub const architecture = __root.alpm_option_add_architecture;
    pub const checkspace = __root.alpm_option_get_checkspace;
    pub const dbext = __root.alpm_option_get_dbext;
    pub const siglevel = __root.alpm_option_get_default_siglevel;
    pub const timeout = __root.alpm_option_get_disable_dl_timeout;
    pub const downloads = __root.alpm_option_get_parallel_downloads;
    pub const sandbox = __root.alpm_option_get_disable_sandbox;
    pub const filesystem = __root.alpm_option_get_disable_sandbox_filesystem;
    pub const syscalls = __root.alpm_option_get_disable_sandbox_syscalls;
    pub const network = __root.alpm_option_get_disable_sandbox_network;
    pub const load = __root.alpm_pkg_load;
    pub const pkgurl = __root.alpm_fetch_pkgurl;
    pub const ignore = __root.alpm_pkg_should_ignore;
    pub const flags = __root.alpm_trans_get_flags;
    pub const add = __root.alpm_trans_get_add;
    pub const init = __root.alpm_trans_init;
    pub const prepare = __root.alpm_trans_prepare;
    pub const commit = __root.alpm_trans_commit;
    pub const interrupt = __root.alpm_trans_interrupt;
    pub const sysupgrade = __root.alpm_sync_sysupgrade;
    pub const pkg = __root.alpm_add_pkg;
    pub const unlock = __root.alpm_unlock;
    pub const child = __root.alpm_sandbox_setup_child;
};
pub const alpm_handle_t = struct__alpm_handle_t;
pub const struct__alpm_db_t = opaque {
    pub const alpm_db_check_pgp_signature = __root.alpm_db_check_pgp_signature;
    pub const alpm_db_unregister = __root.alpm_db_unregister;
    pub const alpm_db_get_handle = __root.alpm_db_get_handle;
    pub const alpm_db_get_name = __root.alpm_db_get_name;
    pub const alpm_db_get_siglevel = __root.alpm_db_get_siglevel;
    pub const alpm_db_get_valid = __root.alpm_db_get_valid;
    pub const alpm_db_get_servers = __root.alpm_db_get_servers;
    pub const alpm_db_set_servers = __root.alpm_db_set_servers;
    pub const alpm_db_add_server = __root.alpm_db_add_server;
    pub const alpm_db_remove_server = __root.alpm_db_remove_server;
    pub const alpm_db_get_cache_servers = __root.alpm_db_get_cache_servers;
    pub const alpm_db_set_cache_servers = __root.alpm_db_set_cache_servers;
    pub const alpm_db_add_cache_server = __root.alpm_db_add_cache_server;
    pub const alpm_db_remove_cache_server = __root.alpm_db_remove_cache_server;
    pub const alpm_db_get_pkg = __root.alpm_db_get_pkg;
    pub const alpm_db_get_pkgcache = __root.alpm_db_get_pkgcache;
    pub const alpm_db_get_group = __root.alpm_db_get_group;
    pub const alpm_db_get_groupcache = __root.alpm_db_get_groupcache;
    pub const alpm_db_search = __root.alpm_db_search;
    pub const alpm_db_set_usage = __root.alpm_db_set_usage;
    pub const alpm_db_get_usage = __root.alpm_db_get_usage;
    pub const signature = __root.alpm_db_check_pgp_signature;
    pub const unregister = __root.alpm_db_unregister;
    pub const handle = __root.alpm_db_get_handle;
    pub const name = __root.alpm_db_get_name;
    pub const siglevel = __root.alpm_db_get_siglevel;
    pub const valid = __root.alpm_db_get_valid;
    pub const servers = __root.alpm_db_get_servers;
    pub const server = __root.alpm_db_add_server;
    pub const pkg = __root.alpm_db_get_pkg;
    pub const pkgcache = __root.alpm_db_get_pkgcache;
    pub const group = __root.alpm_db_get_group;
    pub const groupcache = __root.alpm_db_get_groupcache;
    pub const search = __root.alpm_db_search;
    pub const usage = __root.alpm_db_set_usage;
};
pub const alpm_db_t = struct__alpm_db_t;
pub const struct__alpm_pkg_t = opaque {
    pub const alpm_pkg_check_pgp_signature = __root.alpm_pkg_check_pgp_signature;
    pub const alpm_pkg_free = __root.alpm_pkg_free;
    pub const alpm_pkg_checkmd5sum = __root.alpm_pkg_checkmd5sum;
    pub const alpm_pkg_compute_requiredby = __root.alpm_pkg_compute_requiredby;
    pub const alpm_pkg_compute_optionalfor = __root.alpm_pkg_compute_optionalfor;
    pub const alpm_pkg_get_handle = __root.alpm_pkg_get_handle;
    pub const alpm_pkg_get_filename = __root.alpm_pkg_get_filename;
    pub const alpm_pkg_get_base = __root.alpm_pkg_get_base;
    pub const alpm_pkg_get_name = __root.alpm_pkg_get_name;
    pub const alpm_pkg_get_version = __root.alpm_pkg_get_version;
    pub const alpm_pkg_get_origin = __root.alpm_pkg_get_origin;
    pub const alpm_pkg_get_installed_db = __root.alpm_pkg_get_installed_db;
    pub const alpm_pkg_get_desc = __root.alpm_pkg_get_desc;
    pub const alpm_pkg_get_url = __root.alpm_pkg_get_url;
    pub const alpm_pkg_get_builddate = __root.alpm_pkg_get_builddate;
    pub const alpm_pkg_get_installdate = __root.alpm_pkg_get_installdate;
    pub const alpm_pkg_get_packager = __root.alpm_pkg_get_packager;
    pub const alpm_pkg_get_md5sum = __root.alpm_pkg_get_md5sum;
    pub const alpm_pkg_get_sha256sum = __root.alpm_pkg_get_sha256sum;
    pub const alpm_pkg_get_arch = __root.alpm_pkg_get_arch;
    pub const alpm_pkg_get_size = __root.alpm_pkg_get_size;
    pub const alpm_pkg_get_isize = __root.alpm_pkg_get_isize;
    pub const alpm_pkg_get_reason = __root.alpm_pkg_get_reason;
    pub const alpm_pkg_get_licenses = __root.alpm_pkg_get_licenses;
    pub const alpm_pkg_get_groups = __root.alpm_pkg_get_groups;
    pub const alpm_pkg_get_depends = __root.alpm_pkg_get_depends;
    pub const alpm_pkg_get_optdepends = __root.alpm_pkg_get_optdepends;
    pub const alpm_pkg_get_checkdepends = __root.alpm_pkg_get_checkdepends;
    pub const alpm_pkg_get_makedepends = __root.alpm_pkg_get_makedepends;
    pub const alpm_pkg_get_conflicts = __root.alpm_pkg_get_conflicts;
    pub const alpm_pkg_get_provides = __root.alpm_pkg_get_provides;
    pub const alpm_pkg_get_replaces = __root.alpm_pkg_get_replaces;
    pub const alpm_pkg_get_files = __root.alpm_pkg_get_files;
    pub const alpm_pkg_get_backup = __root.alpm_pkg_get_backup;
    pub const alpm_pkg_get_db = __root.alpm_pkg_get_db;
    pub const alpm_pkg_get_base64_sig = __root.alpm_pkg_get_base64_sig;
    pub const alpm_pkg_get_sig = __root.alpm_pkg_get_sig;
    pub const alpm_pkg_get_validation = __root.alpm_pkg_get_validation;
    pub const alpm_pkg_get_xdata = __root.alpm_pkg_get_xdata;
    pub const alpm_pkg_has_scriptlet = __root.alpm_pkg_has_scriptlet;
    pub const alpm_pkg_download_size = __root.alpm_pkg_download_size;
    pub const alpm_pkg_set_reason = __root.alpm_pkg_set_reason;
    pub const alpm_pkg_changelog_open = __root.alpm_pkg_changelog_open;
    pub const alpm_pkg_changelog_close = __root.alpm_pkg_changelog_close;
    pub const alpm_pkg_mtree_open = __root.alpm_pkg_mtree_open;
    pub const alpm_pkg_mtree_next = __root.alpm_pkg_mtree_next;
    pub const alpm_pkg_mtree_close = __root.alpm_pkg_mtree_close;
    pub const alpm_sync_get_new_version = __root.alpm_sync_get_new_version;
    pub const signature = __root.alpm_pkg_check_pgp_signature;
    pub const checkmd5sum = __root.alpm_pkg_checkmd5sum;
    pub const requiredby = __root.alpm_pkg_compute_requiredby;
    pub const optionalfor = __root.alpm_pkg_compute_optionalfor;
    pub const handle = __root.alpm_pkg_get_handle;
    pub const filename = __root.alpm_pkg_get_filename;
    pub const base = __root.alpm_pkg_get_base;
    pub const name = __root.alpm_pkg_get_name;
    pub const version = __root.alpm_pkg_get_version;
    pub const origin = __root.alpm_pkg_get_origin;
    pub const db = __root.alpm_pkg_get_installed_db;
    pub const desc = __root.alpm_pkg_get_desc;
    pub const url = __root.alpm_pkg_get_url;
    pub const builddate = __root.alpm_pkg_get_builddate;
    pub const installdate = __root.alpm_pkg_get_installdate;
    pub const packager = __root.alpm_pkg_get_packager;
    pub const md5sum = __root.alpm_pkg_get_md5sum;
    pub const sha256sum = __root.alpm_pkg_get_sha256sum;
    pub const arch = __root.alpm_pkg_get_arch;
    pub const size = __root.alpm_pkg_get_size;
    pub const @"isize" = __root.alpm_pkg_get_isize;
    pub const reason = __root.alpm_pkg_get_reason;
    pub const licenses = __root.alpm_pkg_get_licenses;
    pub const groups = __root.alpm_pkg_get_groups;
    pub const depends = __root.alpm_pkg_get_depends;
    pub const optdepends = __root.alpm_pkg_get_optdepends;
    pub const checkdepends = __root.alpm_pkg_get_checkdepends;
    pub const makedepends = __root.alpm_pkg_get_makedepends;
    pub const conflicts = __root.alpm_pkg_get_conflicts;
    pub const provides = __root.alpm_pkg_get_provides;
    pub const replaces = __root.alpm_pkg_get_replaces;
    pub const files = __root.alpm_pkg_get_files;
    pub const backup = __root.alpm_pkg_get_backup;
    pub const sig = __root.alpm_pkg_get_base64_sig;
    pub const validation = __root.alpm_pkg_get_validation;
    pub const xdata = __root.alpm_pkg_get_xdata;
    pub const scriptlet = __root.alpm_pkg_has_scriptlet;
    pub const open = __root.alpm_pkg_changelog_open;
    pub const next = __root.alpm_pkg_mtree_next;
};
pub const alpm_pkg_t = struct__alpm_pkg_t;
pub const struct__alpm_pkg_xdata_t = extern struct {
    name: [*c]u8 = null,
    value: [*c]u8 = null,
};
pub const alpm_pkg_xdata_t = struct__alpm_pkg_xdata_t;
pub const alpm_time_t = i64;
pub const struct__alpm_file_t = extern struct {
    name: [*c]u8 = null,
    size: off_t = 0,
    mode: mode_t = 0,
};
pub const alpm_file_t = struct__alpm_file_t;
pub const struct__alpm_filelist_t = extern struct {
    count: usize = 0,
    files: [*c]alpm_file_t = null,
    pub const alpm_filelist_contains = __root.alpm_filelist_contains;
    pub const contains = __root.alpm_filelist_contains;
};
pub const alpm_filelist_t = struct__alpm_filelist_t;
pub const struct__alpm_backup_t = extern struct {
    name: [*c]u8 = null,
    hash: [*c]u8 = null,
};
pub const alpm_backup_t = struct__alpm_backup_t;
pub extern fn alpm_filelist_contains(filelist: [*c]const alpm_filelist_t, path: [*c]const u8) [*c]alpm_file_t;
pub const struct__alpm_group_t = extern struct {
    name: [*c]u8 = null,
    packages: [*c]alpm_list_t = null,
};
pub const alpm_group_t = struct__alpm_group_t;
pub extern fn alpm_find_group_pkgs(dbs: [*c]alpm_list_t, name: [*c]const u8) [*c]alpm_list_t;
pub const ALPM_ERR_OK: c_int = 0;
pub const ALPM_ERR_MEMORY: c_int = 1;
pub const ALPM_ERR_SYSTEM: c_int = 2;
pub const ALPM_ERR_BADPERMS: c_int = 3;
pub const ALPM_ERR_NOT_A_FILE: c_int = 4;
pub const ALPM_ERR_NOT_A_DIR: c_int = 5;
pub const ALPM_ERR_WRONG_ARGS: c_int = 6;
pub const ALPM_ERR_DISK_SPACE: c_int = 7;
pub const ALPM_ERR_HANDLE_NULL: c_int = 8;
pub const ALPM_ERR_HANDLE_NOT_NULL: c_int = 9;
pub const ALPM_ERR_HANDLE_LOCK: c_int = 10;
pub const ALPM_ERR_DB_OPEN: c_int = 11;
pub const ALPM_ERR_DB_CREATE: c_int = 12;
pub const ALPM_ERR_DB_NULL: c_int = 13;
pub const ALPM_ERR_DB_NOT_NULL: c_int = 14;
pub const ALPM_ERR_DB_NOT_FOUND: c_int = 15;
pub const ALPM_ERR_DB_INVALID: c_int = 16;
pub const ALPM_ERR_DB_INVALID_SIG: c_int = 17;
pub const ALPM_ERR_DB_VERSION: c_int = 18;
pub const ALPM_ERR_DB_WRITE: c_int = 19;
pub const ALPM_ERR_DB_REMOVE: c_int = 20;
pub const ALPM_ERR_SERVER_BAD_URL: c_int = 21;
pub const ALPM_ERR_SERVER_NONE: c_int = 22;
pub const ALPM_ERR_TRANS_NOT_NULL: c_int = 23;
pub const ALPM_ERR_TRANS_NULL: c_int = 24;
pub const ALPM_ERR_TRANS_DUP_TARGET: c_int = 25;
pub const ALPM_ERR_TRANS_DUP_FILENAME: c_int = 26;
pub const ALPM_ERR_TRANS_NOT_INITIALIZED: c_int = 27;
pub const ALPM_ERR_TRANS_NOT_PREPARED: c_int = 28;
pub const ALPM_ERR_TRANS_ABORT: c_int = 29;
pub const ALPM_ERR_TRANS_TYPE: c_int = 30;
pub const ALPM_ERR_TRANS_NOT_LOCKED: c_int = 31;
pub const ALPM_ERR_TRANS_HOOK_FAILED: c_int = 32;
pub const ALPM_ERR_PKG_NOT_FOUND: c_int = 33;
pub const ALPM_ERR_PKG_IGNORED: c_int = 34;
pub const ALPM_ERR_PKG_INVALID: c_int = 35;
pub const ALPM_ERR_PKG_INVALID_CHECKSUM: c_int = 36;
pub const ALPM_ERR_PKG_INVALID_SIG: c_int = 37;
pub const ALPM_ERR_PKG_MISSING_SIG: c_int = 38;
pub const ALPM_ERR_PKG_OPEN: c_int = 39;
pub const ALPM_ERR_PKG_CANT_REMOVE: c_int = 40;
pub const ALPM_ERR_PKG_INVALID_NAME: c_int = 41;
pub const ALPM_ERR_PKG_INVALID_ARCH: c_int = 42;
pub const ALPM_ERR_SIG_MISSING: c_int = 43;
pub const ALPM_ERR_SIG_INVALID: c_int = 44;
pub const ALPM_ERR_UNSATISFIED_DEPS: c_int = 45;
pub const ALPM_ERR_CONFLICTING_DEPS: c_int = 46;
pub const ALPM_ERR_FILE_CONFLICTS: c_int = 47;
pub const ALPM_ERR_RETRIEVE_PREPARE: c_int = 48;
pub const ALPM_ERR_RETRIEVE: c_int = 49;
pub const ALPM_ERR_INVALID_REGEX: c_int = 50;
pub const ALPM_ERR_LIBARCHIVE: c_int = 51;
pub const ALPM_ERR_LIBCURL: c_int = 52;
pub const ALPM_ERR_EXTERNAL_DOWNLOAD: c_int = 53;
pub const ALPM_ERR_GPGME: c_int = 54;
pub const ALPM_ERR_MISSING_CAPABILITY_SIGNATURES: c_int = 55;
pub const enum__alpm_errno_t = c_uint;
pub const alpm_errno_t = enum__alpm_errno_t;
pub extern fn alpm_errno(handle: ?*alpm_handle_t) alpm_errno_t;
pub extern fn alpm_strerror(err: alpm_errno_t) [*c]const u8;
pub extern fn alpm_initialize(root: [*c]const u8, dbpath: [*c]const u8, err: [*c]alpm_errno_t) ?*alpm_handle_t;
pub extern fn alpm_release(handle: ?*alpm_handle_t) c_int;
pub const ALPM_SIG_PACKAGE: c_int = 1;
pub const ALPM_SIG_PACKAGE_OPTIONAL: c_int = 2;
pub const ALPM_SIG_PACKAGE_MARGINAL_OK: c_int = 4;
pub const ALPM_SIG_PACKAGE_UNKNOWN_OK: c_int = 8;
pub const ALPM_SIG_DATABASE: c_int = 1024;
pub const ALPM_SIG_DATABASE_OPTIONAL: c_int = 2048;
pub const ALPM_SIG_DATABASE_MARGINAL_OK: c_int = 4096;
pub const ALPM_SIG_DATABASE_UNKNOWN_OK: c_int = 8192;
pub const ALPM_SIG_USE_DEFAULT: c_int = 1073741824;
pub const enum__alpm_siglevel_t = c_uint;
pub const alpm_siglevel_t = enum__alpm_siglevel_t;
pub const ALPM_SIGSTATUS_VALID: c_int = 0;
pub const ALPM_SIGSTATUS_KEY_EXPIRED: c_int = 1;
pub const ALPM_SIGSTATUS_SIG_EXPIRED: c_int = 2;
pub const ALPM_SIGSTATUS_KEY_UNKNOWN: c_int = 3;
pub const ALPM_SIGSTATUS_KEY_DISABLED: c_int = 4;
pub const ALPM_SIGSTATUS_INVALID: c_int = 5;
pub const enum__alpm_sigstatus_t = c_uint;
pub const alpm_sigstatus_t = enum__alpm_sigstatus_t;
pub const ALPM_SIGVALIDITY_FULL: c_int = 0;
pub const ALPM_SIGVALIDITY_MARGINAL: c_int = 1;
pub const ALPM_SIGVALIDITY_NEVER: c_int = 2;
pub const ALPM_SIGVALIDITY_UNKNOWN: c_int = 3;
pub const enum__alpm_sigvalidity_t = c_uint;
pub const alpm_sigvalidity_t = enum__alpm_sigvalidity_t;
pub const struct__alpm_pgpkey_t = extern struct {
    data: ?*anyopaque = null,
    fingerprint: [*c]u8 = null,
    uid: [*c]u8 = null,
    name: [*c]u8 = null,
    email: [*c]u8 = null,
    created: alpm_time_t = 0,
    expires: alpm_time_t = 0,
    length: c_uint = 0,
    revoked: c_uint = 0,
};
pub const alpm_pgpkey_t = struct__alpm_pgpkey_t;
pub const struct__alpm_sigresult_t = extern struct {
    key: alpm_pgpkey_t = @import("std").mem.zeroes(alpm_pgpkey_t),
    status: alpm_sigstatus_t = @import("std").mem.zeroes(alpm_sigstatus_t),
    validity: alpm_sigvalidity_t = @import("std").mem.zeroes(alpm_sigvalidity_t),
};
pub const alpm_sigresult_t = struct__alpm_sigresult_t;
pub const struct__alpm_siglist_t = extern struct {
    count: usize = 0,
    results: [*c]alpm_sigresult_t = null,
    pub const alpm_siglist_cleanup = __root.alpm_siglist_cleanup;
    pub const cleanup = __root.alpm_siglist_cleanup;
};
pub const alpm_siglist_t = struct__alpm_siglist_t;
pub extern fn alpm_pkg_check_pgp_signature(pkg: ?*alpm_pkg_t, siglist: [*c]alpm_siglist_t) c_int;
pub extern fn alpm_db_check_pgp_signature(db: ?*alpm_db_t, siglist: [*c]alpm_siglist_t) c_int;
pub extern fn alpm_siglist_cleanup(siglist: [*c]alpm_siglist_t) c_int;
pub extern fn alpm_decode_signature(base64_data: [*c]const u8, data: [*c][*c]u8, data_len: [*c]usize) c_int;
pub extern fn alpm_extract_keyid(handle: ?*alpm_handle_t, identifier: [*c]const u8, sig: [*c]const u8, len: usize, keys: [*c][*c]alpm_list_t) c_int;
pub const ALPM_DEP_MOD_ANY: c_int = 1;
pub const ALPM_DEP_MOD_EQ: c_int = 2;
pub const ALPM_DEP_MOD_GE: c_int = 3;
pub const ALPM_DEP_MOD_LE: c_int = 4;
pub const ALPM_DEP_MOD_GT: c_int = 5;
pub const ALPM_DEP_MOD_LT: c_int = 6;
pub const enum__alpm_depmod_t = c_uint;
pub const alpm_depmod_t = enum__alpm_depmod_t;
pub const ALPM_FILECONFLICT_TARGET: c_int = 1;
pub const ALPM_FILECONFLICT_FILESYSTEM: c_int = 2;
pub const enum__alpm_fileconflicttype_t = c_uint;
pub const alpm_fileconflicttype_t = enum__alpm_fileconflicttype_t;
pub const struct__alpm_depend_t = extern struct {
    name: [*c]u8 = null,
    version: [*c]u8 = null,
    desc: [*c]u8 = null,
    name_hash: c_ulong = 0,
    mod: alpm_depmod_t = @import("std").mem.zeroes(alpm_depmod_t),
    pub const alpm_dep_compute_string = __root.alpm_dep_compute_string;
    pub const alpm_dep_free = __root.alpm_dep_free;
    pub const string = __root.alpm_dep_compute_string;
};
pub const alpm_depend_t = struct__alpm_depend_t;
pub const struct__alpm_depmissing_t = extern struct {
    target: [*c]u8 = null,
    depend: [*c]alpm_depend_t = null,
    causingpkg: [*c]u8 = null,
    pub const alpm_depmissing_free = __root.alpm_depmissing_free;
};
pub const alpm_depmissing_t = struct__alpm_depmissing_t;
pub const struct__alpm_conflict_t = extern struct {
    package1: ?*alpm_pkg_t = null,
    package2: ?*alpm_pkg_t = null,
    reason: [*c]alpm_depend_t = null,
    pub const alpm_conflict_free = __root.alpm_conflict_free;
};
pub const alpm_conflict_t = struct__alpm_conflict_t;
pub const struct__alpm_fileconflict_t = extern struct {
    target: [*c]u8 = null,
    type: alpm_fileconflicttype_t = @import("std").mem.zeroes(alpm_fileconflicttype_t),
    file: [*c]u8 = null,
    ctarget: [*c]u8 = null,
    pub const alpm_fileconflict_free = __root.alpm_fileconflict_free;
};
pub const alpm_fileconflict_t = struct__alpm_fileconflict_t;
pub extern fn alpm_checkdeps(handle: ?*alpm_handle_t, pkglist: [*c]alpm_list_t, remove: [*c]alpm_list_t, upgrade: [*c]alpm_list_t, reversedeps: c_int) [*c]alpm_list_t;
pub extern fn alpm_find_satisfier(pkgs: [*c]alpm_list_t, depstring: [*c]const u8) ?*alpm_pkg_t;
pub extern fn alpm_find_dbs_satisfier(handle: ?*alpm_handle_t, dbs: [*c]alpm_list_t, depstring: [*c]const u8) ?*alpm_pkg_t;
pub extern fn alpm_checkconflicts(handle: ?*alpm_handle_t, pkglist: [*c]alpm_list_t) [*c]alpm_list_t;
pub extern fn alpm_dep_compute_string(dep: [*c]const alpm_depend_t) [*c]u8;
pub extern fn alpm_dep_from_string(depstring: [*c]const u8) [*c]alpm_depend_t;
pub extern fn alpm_dep_free(dep: [*c]alpm_depend_t) void;
pub extern fn alpm_fileconflict_free(conflict: [*c]alpm_fileconflict_t) void;
pub extern fn alpm_depmissing_free(miss: [*c]alpm_depmissing_t) void;
pub extern fn alpm_conflict_free(conflict: [*c]alpm_conflict_t) void;
pub const ALPM_EVENT_CHECKDEPS_START: c_int = 1;
pub const ALPM_EVENT_CHECKDEPS_DONE: c_int = 2;
pub const ALPM_EVENT_FILECONFLICTS_START: c_int = 3;
pub const ALPM_EVENT_FILECONFLICTS_DONE: c_int = 4;
pub const ALPM_EVENT_RESOLVEDEPS_START: c_int = 5;
pub const ALPM_EVENT_RESOLVEDEPS_DONE: c_int = 6;
pub const ALPM_EVENT_INTERCONFLICTS_START: c_int = 7;
pub const ALPM_EVENT_INTERCONFLICTS_DONE: c_int = 8;
pub const ALPM_EVENT_TRANSACTION_START: c_int = 9;
pub const ALPM_EVENT_TRANSACTION_DONE: c_int = 10;
pub const ALPM_EVENT_PACKAGE_OPERATION_START: c_int = 11;
pub const ALPM_EVENT_PACKAGE_OPERATION_DONE: c_int = 12;
pub const ALPM_EVENT_INTEGRITY_START: c_int = 13;
pub const ALPM_EVENT_INTEGRITY_DONE: c_int = 14;
pub const ALPM_EVENT_LOAD_START: c_int = 15;
pub const ALPM_EVENT_LOAD_DONE: c_int = 16;
pub const ALPM_EVENT_SCRIPTLET_INFO: c_int = 17;
pub const ALPM_EVENT_DB_RETRIEVE_START: c_int = 18;
pub const ALPM_EVENT_DB_RETRIEVE_DONE: c_int = 19;
pub const ALPM_EVENT_DB_RETRIEVE_FAILED: c_int = 20;
pub const ALPM_EVENT_PKG_RETRIEVE_START: c_int = 21;
pub const ALPM_EVENT_PKG_RETRIEVE_DONE: c_int = 22;
pub const ALPM_EVENT_PKG_RETRIEVE_FAILED: c_int = 23;
pub const ALPM_EVENT_DISKSPACE_START: c_int = 24;
pub const ALPM_EVENT_DISKSPACE_DONE: c_int = 25;
pub const ALPM_EVENT_OPTDEP_REMOVAL: c_int = 26;
pub const ALPM_EVENT_DATABASE_MISSING: c_int = 27;
pub const ALPM_EVENT_KEYRING_START: c_int = 28;
pub const ALPM_EVENT_KEYRING_DONE: c_int = 29;
pub const ALPM_EVENT_KEY_DOWNLOAD_START: c_int = 30;
pub const ALPM_EVENT_KEY_DOWNLOAD_DONE: c_int = 31;
pub const ALPM_EVENT_PACNEW_CREATED: c_int = 32;
pub const ALPM_EVENT_PACSAVE_CREATED: c_int = 33;
pub const ALPM_EVENT_HOOK_START: c_int = 34;
pub const ALPM_EVENT_HOOK_DONE: c_int = 35;
pub const ALPM_EVENT_HOOK_RUN_START: c_int = 36;
pub const ALPM_EVENT_HOOK_RUN_DONE: c_int = 37;
pub const enum__alpm_event_type_t = c_uint;
pub const alpm_event_type_t = enum__alpm_event_type_t;
pub const struct__alpm_event_any_t = extern struct {
    type: alpm_event_type_t = @import("std").mem.zeroes(alpm_event_type_t),
};
pub const alpm_event_any_t = struct__alpm_event_any_t;
pub const ALPM_PACKAGE_INSTALL: c_int = 1;
pub const ALPM_PACKAGE_UPGRADE: c_int = 2;
pub const ALPM_PACKAGE_REINSTALL: c_int = 3;
pub const ALPM_PACKAGE_DOWNGRADE: c_int = 4;
pub const ALPM_PACKAGE_REMOVE: c_int = 5;
pub const enum__alpm_package_operation_t = c_uint;
pub const alpm_package_operation_t = enum__alpm_package_operation_t;
pub const struct__alpm_event_package_operation_t = extern struct {
    type: alpm_event_type_t = @import("std").mem.zeroes(alpm_event_type_t),
    operation: alpm_package_operation_t = @import("std").mem.zeroes(alpm_package_operation_t),
    oldpkg: ?*alpm_pkg_t = null,
    newpkg: ?*alpm_pkg_t = null,
};
pub const alpm_event_package_operation_t = struct__alpm_event_package_operation_t;
pub const struct__alpm_event_optdep_removal_t = extern struct {
    type: alpm_event_type_t = @import("std").mem.zeroes(alpm_event_type_t),
    pkg: ?*alpm_pkg_t = null,
    optdep: [*c]alpm_depend_t = null,
};
pub const alpm_event_optdep_removal_t = struct__alpm_event_optdep_removal_t;
pub const struct__alpm_event_scriptlet_info_t = extern struct {
    type: alpm_event_type_t = @import("std").mem.zeroes(alpm_event_type_t),
    line: [*c]const u8 = null,
};
pub const alpm_event_scriptlet_info_t = struct__alpm_event_scriptlet_info_t;
pub const struct__alpm_event_database_missing_t = extern struct {
    type: alpm_event_type_t = @import("std").mem.zeroes(alpm_event_type_t),
    dbname: [*c]const u8 = null,
};
pub const alpm_event_database_missing_t = struct__alpm_event_database_missing_t;
pub const struct__alpm_event_pkgdownload_t = extern struct {
    type: alpm_event_type_t = @import("std").mem.zeroes(alpm_event_type_t),
    file: [*c]const u8 = null,
};
pub const alpm_event_pkgdownload_t = struct__alpm_event_pkgdownload_t;
pub const struct__alpm_event_pacnew_created_t = extern struct {
    type: alpm_event_type_t = @import("std").mem.zeroes(alpm_event_type_t),
    from_noupgrade: c_int = 0,
    oldpkg: ?*alpm_pkg_t = null,
    newpkg: ?*alpm_pkg_t = null,
    file: [*c]const u8 = null,
};
pub const alpm_event_pacnew_created_t = struct__alpm_event_pacnew_created_t;
pub const struct__alpm_event_pacsave_created_t = extern struct {
    type: alpm_event_type_t = @import("std").mem.zeroes(alpm_event_type_t),
    oldpkg: ?*alpm_pkg_t = null,
    file: [*c]const u8 = null,
};
pub const alpm_event_pacsave_created_t = struct__alpm_event_pacsave_created_t;
pub const ALPM_HOOK_PRE_TRANSACTION: c_int = 1;
pub const ALPM_HOOK_POST_TRANSACTION: c_int = 2;
pub const enum__alpm_hook_when_t = c_uint;
pub const alpm_hook_when_t = enum__alpm_hook_when_t;
pub const struct__alpm_event_hook_t = extern struct {
    type: alpm_event_type_t = @import("std").mem.zeroes(alpm_event_type_t),
    when: alpm_hook_when_t = @import("std").mem.zeroes(alpm_hook_when_t),
};
pub const alpm_event_hook_t = struct__alpm_event_hook_t;
pub const struct__alpm_event_hook_run_t = extern struct {
    type: alpm_event_type_t = @import("std").mem.zeroes(alpm_event_type_t),
    name: [*c]const u8 = null,
    desc: [*c]const u8 = null,
    position: usize = 0,
    total: usize = 0,
};
pub const alpm_event_hook_run_t = struct__alpm_event_hook_run_t;
pub const struct__alpm_event_pkg_retrieve_t = extern struct {
    type: alpm_event_type_t = @import("std").mem.zeroes(alpm_event_type_t),
    num: usize = 0,
    total_size: off_t = 0,
};
pub const alpm_event_pkg_retrieve_t = struct__alpm_event_pkg_retrieve_t;
pub const union__alpm_event_t = extern union {
    type: alpm_event_type_t,
    any: alpm_event_any_t,
    package_operation: alpm_event_package_operation_t,
    optdep_removal: alpm_event_optdep_removal_t,
    scriptlet_info: alpm_event_scriptlet_info_t,
    database_missing: alpm_event_database_missing_t,
    pkgdownload: alpm_event_pkgdownload_t,
    pacnew_created: alpm_event_pacnew_created_t,
    pacsave_created: alpm_event_pacsave_created_t,
    hook: alpm_event_hook_t,
    hook_run: alpm_event_hook_run_t,
    pkg_retrieve: alpm_event_pkg_retrieve_t,
};
pub const alpm_event_t = union__alpm_event_t;
pub const alpm_cb_event = ?*const fn (ctx: ?*anyopaque, event: [*c]alpm_event_t) callconv(.c) void;
pub const ALPM_QUESTION_INSTALL_IGNOREPKG: c_int = 1;
pub const ALPM_QUESTION_REPLACE_PKG: c_int = 2;
pub const ALPM_QUESTION_CONFLICT_PKG: c_int = 4;
pub const ALPM_QUESTION_CORRUPTED_PKG: c_int = 8;
pub const ALPM_QUESTION_REMOVE_PKGS: c_int = 16;
pub const ALPM_QUESTION_SELECT_PROVIDER: c_int = 32;
pub const ALPM_QUESTION_IMPORT_KEY: c_int = 64;
pub const enum__alpm_question_type_t = c_uint;
pub const alpm_question_type_t = enum__alpm_question_type_t;
pub const struct__alpm_question_any_t = extern struct {
    type: alpm_question_type_t = @import("std").mem.zeroes(alpm_question_type_t),
    answer: c_int = 0,
};
pub const alpm_question_any_t = struct__alpm_question_any_t;
pub const struct__alpm_question_install_ignorepkg_t = extern struct {
    type: alpm_question_type_t = @import("std").mem.zeroes(alpm_question_type_t),
    install: c_int = 0,
    pkg: ?*alpm_pkg_t = null,
};
pub const alpm_question_install_ignorepkg_t = struct__alpm_question_install_ignorepkg_t;
pub const struct__alpm_question_replace_t = extern struct {
    type: alpm_question_type_t = @import("std").mem.zeroes(alpm_question_type_t),
    replace: c_int = 0,
    oldpkg: ?*alpm_pkg_t = null,
    newpkg: ?*alpm_pkg_t = null,
    newdb: ?*alpm_db_t = null,
};
pub const alpm_question_replace_t = struct__alpm_question_replace_t;
pub const struct__alpm_question_conflict_t = extern struct {
    type: alpm_question_type_t = @import("std").mem.zeroes(alpm_question_type_t),
    remove: c_int = 0,
    conflict: [*c]alpm_conflict_t = null,
};
pub const alpm_question_conflict_t = struct__alpm_question_conflict_t;
pub const struct__alpm_question_corrupted_t = extern struct {
    type: alpm_question_type_t = @import("std").mem.zeroes(alpm_question_type_t),
    remove: c_int = 0,
    filepath: [*c]const u8 = null,
    reason: alpm_errno_t = @import("std").mem.zeroes(alpm_errno_t),
};
pub const alpm_question_corrupted_t = struct__alpm_question_corrupted_t;
pub const struct__alpm_question_remove_pkgs_t = extern struct {
    type: alpm_question_type_t = @import("std").mem.zeroes(alpm_question_type_t),
    skip: c_int = 0,
    packages: [*c]alpm_list_t = null,
};
pub const alpm_question_remove_pkgs_t = struct__alpm_question_remove_pkgs_t;
pub const struct__alpm_question_select_provider_t = extern struct {
    type: alpm_question_type_t = @import("std").mem.zeroes(alpm_question_type_t),
    use_index: c_int = 0,
    providers: [*c]alpm_list_t = null,
    depend: [*c]alpm_depend_t = null,
};
pub const alpm_question_select_provider_t = struct__alpm_question_select_provider_t;
pub const struct__alpm_question_import_key_t = extern struct {
    type: alpm_question_type_t = @import("std").mem.zeroes(alpm_question_type_t),
    import: c_int = 0,
    uid: [*c]const u8 = null,
    fingerprint: [*c]const u8 = null,
};
pub const alpm_question_import_key_t = struct__alpm_question_import_key_t;
pub const union__alpm_question_t = extern union {
    type: alpm_question_type_t,
    any: alpm_question_any_t,
    install_ignorepkg: alpm_question_install_ignorepkg_t,
    replace: alpm_question_replace_t,
    conflict: alpm_question_conflict_t,
    corrupted: alpm_question_corrupted_t,
    remove_pkgs: alpm_question_remove_pkgs_t,
    select_provider: alpm_question_select_provider_t,
    import_key: alpm_question_import_key_t,
};
pub const alpm_question_t = union__alpm_question_t;
pub const alpm_cb_question = ?*const fn (ctx: ?*anyopaque, question: [*c]alpm_question_t) callconv(.c) void;
pub const ALPM_PROGRESS_ADD_START: c_int = 0;
pub const ALPM_PROGRESS_UPGRADE_START: c_int = 1;
pub const ALPM_PROGRESS_DOWNGRADE_START: c_int = 2;
pub const ALPM_PROGRESS_REINSTALL_START: c_int = 3;
pub const ALPM_PROGRESS_REMOVE_START: c_int = 4;
pub const ALPM_PROGRESS_CONFLICTS_START: c_int = 5;
pub const ALPM_PROGRESS_DISKSPACE_START: c_int = 6;
pub const ALPM_PROGRESS_INTEGRITY_START: c_int = 7;
pub const ALPM_PROGRESS_LOAD_START: c_int = 8;
pub const ALPM_PROGRESS_KEYRING_START: c_int = 9;
pub const enum__alpm_progress_t = c_uint;
pub const alpm_progress_t = enum__alpm_progress_t;
pub const alpm_cb_progress = ?*const fn (ctx: ?*anyopaque, progress: alpm_progress_t, pkg: [*c]const u8, percent: c_int, howmany: usize, current: usize) callconv(.c) void;
pub const ALPM_DOWNLOAD_INIT: c_int = 0;
pub const ALPM_DOWNLOAD_PROGRESS: c_int = 1;
pub const ALPM_DOWNLOAD_RETRY: c_int = 2;
pub const ALPM_DOWNLOAD_COMPLETED: c_int = 3;
pub const enum__alpm_download_event_type_t = c_uint;
pub const alpm_download_event_type_t = enum__alpm_download_event_type_t;
pub const struct__alpm_download_event_init_t = extern struct {
    optional: c_int = 0,
};
pub const alpm_download_event_init_t = struct__alpm_download_event_init_t;
pub const struct__alpm_download_event_progress_t = extern struct {
    downloaded: off_t = 0,
    total: off_t = 0,
};
pub const alpm_download_event_progress_t = struct__alpm_download_event_progress_t;
pub const struct__alpm_download_event_retry_t = extern struct {
    @"resume": c_int = 0,
};
pub const alpm_download_event_retry_t = struct__alpm_download_event_retry_t;
pub const struct__alpm_download_event_completed_t = extern struct {
    total: off_t = 0,
    result: c_int = 0,
};
pub const alpm_download_event_completed_t = struct__alpm_download_event_completed_t;
pub const alpm_cb_download = ?*const fn (ctx: ?*anyopaque, filename: [*c]const u8, event: alpm_download_event_type_t, data: ?*anyopaque) callconv(.c) void;
pub const alpm_cb_fetch = ?*const fn (ctx: ?*anyopaque, url: [*c]const u8, localpath: [*c]const u8, force: c_int) callconv(.c) c_int;
pub extern fn alpm_get_localdb(handle: ?*alpm_handle_t) ?*alpm_db_t;
pub extern fn alpm_get_syncdbs(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_register_syncdb(handle: ?*alpm_handle_t, treename: [*c]const u8, level: c_int) ?*alpm_db_t;
pub extern fn alpm_unregister_all_syncdbs(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_db_unregister(db: ?*alpm_db_t) c_int;
pub extern fn alpm_db_get_handle(db: ?*alpm_db_t) ?*alpm_handle_t;
pub extern fn alpm_db_get_name(db: ?*const alpm_db_t) [*c]const u8;
pub extern fn alpm_db_get_siglevel(db: ?*alpm_db_t) c_int;
pub extern fn alpm_db_get_valid(db: ?*alpm_db_t) c_int;
pub extern fn alpm_db_get_servers(db: ?*const alpm_db_t) [*c]alpm_list_t;
pub extern fn alpm_db_set_servers(db: ?*alpm_db_t, servers: [*c]alpm_list_t) c_int;
pub extern fn alpm_db_add_server(db: ?*alpm_db_t, url: [*c]const u8) c_int;
pub extern fn alpm_db_remove_server(db: ?*alpm_db_t, url: [*c]const u8) c_int;
pub extern fn alpm_db_get_cache_servers(db: ?*const alpm_db_t) [*c]alpm_list_t;
pub extern fn alpm_db_set_cache_servers(db: ?*alpm_db_t, servers: [*c]alpm_list_t) c_int;
pub extern fn alpm_db_add_cache_server(db: ?*alpm_db_t, url: [*c]const u8) c_int;
pub extern fn alpm_db_remove_cache_server(db: ?*alpm_db_t, url: [*c]const u8) c_int;
pub extern fn alpm_db_update(handle: ?*alpm_handle_t, dbs: [*c]alpm_list_t, force: c_int) c_int;
pub extern fn alpm_db_get_pkg(db: ?*alpm_db_t, name: [*c]const u8) ?*alpm_pkg_t;
pub extern fn alpm_db_get_pkgcache(db: ?*alpm_db_t) [*c]alpm_list_t;
pub extern fn alpm_db_get_group(db: ?*alpm_db_t, name: [*c]const u8) [*c]alpm_group_t;
pub extern fn alpm_db_get_groupcache(db: ?*alpm_db_t) [*c]alpm_list_t;
pub extern fn alpm_db_search(db: ?*alpm_db_t, needles: [*c]const alpm_list_t, ret: [*c][*c]alpm_list_t) c_int;
pub const ALPM_DB_USAGE_SYNC: c_int = 1;
pub const ALPM_DB_USAGE_SEARCH: c_int = 2;
pub const ALPM_DB_USAGE_INSTALL: c_int = 4;
pub const ALPM_DB_USAGE_UPGRADE: c_int = 8;
pub const ALPM_DB_USAGE_ALL: c_int = 15;
pub const enum__alpm_db_usage_t = c_uint;
pub const alpm_db_usage_t = enum__alpm_db_usage_t;
pub extern fn alpm_db_set_usage(db: ?*alpm_db_t, usage: c_int) c_int;
pub extern fn alpm_db_get_usage(db: ?*alpm_db_t, usage: [*c]c_int) c_int;
pub const ALPM_LOG_ERROR: c_int = 1;
pub const ALPM_LOG_WARNING: c_int = 2;
pub const ALPM_LOG_DEBUG: c_int = 4;
pub const ALPM_LOG_FUNCTION: c_int = 8;
pub const enum__alpm_loglevel_t = c_uint;
pub const alpm_loglevel_t = enum__alpm_loglevel_t;
pub const alpm_cb_log = ?*const fn (ctx: ?*anyopaque, level: alpm_loglevel_t, fmt: [*c]const u8, args: [*c]struct___va_list_tag_2) callconv(.c) void;
pub extern fn alpm_logaction(handle: ?*alpm_handle_t, prefix: [*c]const u8, fmt: [*c]const u8, ...) c_int;
pub extern fn alpm_option_get_logcb(handle: ?*alpm_handle_t) alpm_cb_log;
pub extern fn alpm_option_get_logcb_ctx(handle: ?*alpm_handle_t) ?*anyopaque;
pub extern fn alpm_option_set_logcb(handle: ?*alpm_handle_t, cb: alpm_cb_log, ctx: ?*anyopaque) c_int;
pub extern fn alpm_option_get_dlcb(handle: ?*alpm_handle_t) alpm_cb_download;
pub extern fn alpm_option_get_dlcb_ctx(handle: ?*alpm_handle_t) ?*anyopaque;
pub extern fn alpm_option_set_dlcb(handle: ?*alpm_handle_t, cb: alpm_cb_download, ctx: ?*anyopaque) c_int;
pub extern fn alpm_option_get_fetchcb(handle: ?*alpm_handle_t) alpm_cb_fetch;
pub extern fn alpm_option_get_fetchcb_ctx(handle: ?*alpm_handle_t) ?*anyopaque;
pub extern fn alpm_option_set_fetchcb(handle: ?*alpm_handle_t, cb: alpm_cb_fetch, ctx: ?*anyopaque) c_int;
pub extern fn alpm_option_get_eventcb(handle: ?*alpm_handle_t) alpm_cb_event;
pub extern fn alpm_option_get_eventcb_ctx(handle: ?*alpm_handle_t) ?*anyopaque;
pub extern fn alpm_option_set_eventcb(handle: ?*alpm_handle_t, cb: alpm_cb_event, ctx: ?*anyopaque) c_int;
pub extern fn alpm_option_get_questioncb(handle: ?*alpm_handle_t) alpm_cb_question;
pub extern fn alpm_option_get_questioncb_ctx(handle: ?*alpm_handle_t) ?*anyopaque;
pub extern fn alpm_option_set_questioncb(handle: ?*alpm_handle_t, cb: alpm_cb_question, ctx: ?*anyopaque) c_int;
pub extern fn alpm_option_get_progresscb(handle: ?*alpm_handle_t) alpm_cb_progress;
pub extern fn alpm_option_get_progresscb_ctx(handle: ?*alpm_handle_t) ?*anyopaque;
pub extern fn alpm_option_set_progresscb(handle: ?*alpm_handle_t, cb: alpm_cb_progress, ctx: ?*anyopaque) c_int;
pub extern fn alpm_option_get_root(handle: ?*alpm_handle_t) [*c]const u8;
pub extern fn alpm_option_get_dbpath(handle: ?*alpm_handle_t) [*c]const u8;
pub extern fn alpm_option_get_lockfile(handle: ?*alpm_handle_t) [*c]const u8;
pub extern fn alpm_option_get_cachedirs(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_option_set_cachedirs(handle: ?*alpm_handle_t, cachedirs: [*c]alpm_list_t) c_int;
pub extern fn alpm_option_add_cachedir(handle: ?*alpm_handle_t, cachedir: [*c]const u8) c_int;
pub extern fn alpm_option_remove_cachedir(handle: ?*alpm_handle_t, cachedir: [*c]const u8) c_int;
pub extern fn alpm_option_get_hookdirs(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_option_set_hookdirs(handle: ?*alpm_handle_t, hookdirs: [*c]alpm_list_t) c_int;
pub extern fn alpm_option_add_hookdir(handle: ?*alpm_handle_t, hookdir: [*c]const u8) c_int;
pub extern fn alpm_option_remove_hookdir(handle: ?*alpm_handle_t, hookdir: [*c]const u8) c_int;
pub extern fn alpm_option_get_overwrite_files(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_option_set_overwrite_files(handle: ?*alpm_handle_t, globs: [*c]alpm_list_t) c_int;
pub extern fn alpm_option_add_overwrite_file(handle: ?*alpm_handle_t, glob: [*c]const u8) c_int;
pub extern fn alpm_option_remove_overwrite_file(handle: ?*alpm_handle_t, glob: [*c]const u8) c_int;
pub extern fn alpm_option_get_logfile(handle: ?*alpm_handle_t) [*c]const u8;
pub extern fn alpm_option_set_logfile(handle: ?*alpm_handle_t, logfile: [*c]const u8) c_int;
pub extern fn alpm_option_get_gpgdir(handle: ?*alpm_handle_t) [*c]const u8;
pub extern fn alpm_option_set_gpgdir(handle: ?*alpm_handle_t, gpgdir: [*c]const u8) c_int;
pub extern fn alpm_option_get_sandboxuser(handle: ?*alpm_handle_t) [*c]const u8;
pub extern fn alpm_option_set_sandboxuser(handle: ?*alpm_handle_t, sandboxuser: [*c]const u8) c_int;
pub extern fn alpm_option_get_usesyslog(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_option_set_usesyslog(handle: ?*alpm_handle_t, usesyslog: c_int) c_int;
pub extern fn alpm_option_get_noupgrades(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_option_add_noupgrade(handle: ?*alpm_handle_t, path: [*c]const u8) c_int;
pub extern fn alpm_option_set_noupgrades(handle: ?*alpm_handle_t, noupgrade: [*c]alpm_list_t) c_int;
pub extern fn alpm_option_remove_noupgrade(handle: ?*alpm_handle_t, path: [*c]const u8) c_int;
pub extern fn alpm_option_match_noupgrade(handle: ?*alpm_handle_t, path: [*c]const u8) c_int;
pub extern fn alpm_option_get_noextracts(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_option_add_noextract(handle: ?*alpm_handle_t, path: [*c]const u8) c_int;
pub extern fn alpm_option_set_noextracts(handle: ?*alpm_handle_t, noextract: [*c]alpm_list_t) c_int;
pub extern fn alpm_option_remove_noextract(handle: ?*alpm_handle_t, path: [*c]const u8) c_int;
pub extern fn alpm_option_match_noextract(handle: ?*alpm_handle_t, path: [*c]const u8) c_int;
pub extern fn alpm_option_get_ignorepkgs(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_option_add_ignorepkg(handle: ?*alpm_handle_t, pkg: [*c]const u8) c_int;
pub extern fn alpm_option_set_ignorepkgs(handle: ?*alpm_handle_t, ignorepkgs: [*c]alpm_list_t) c_int;
pub extern fn alpm_option_remove_ignorepkg(handle: ?*alpm_handle_t, pkg: [*c]const u8) c_int;
pub extern fn alpm_option_get_ignoregroups(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_option_add_ignoregroup(handle: ?*alpm_handle_t, grp: [*c]const u8) c_int;
pub extern fn alpm_option_set_ignoregroups(handle: ?*alpm_handle_t, ignoregrps: [*c]alpm_list_t) c_int;
pub extern fn alpm_option_remove_ignoregroup(handle: ?*alpm_handle_t, grp: [*c]const u8) c_int;
pub extern fn alpm_option_get_assumeinstalled(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_option_add_assumeinstalled(handle: ?*alpm_handle_t, dep: [*c]const alpm_depend_t) c_int;
pub extern fn alpm_option_set_assumeinstalled(handle: ?*alpm_handle_t, deps: [*c]alpm_list_t) c_int;
pub extern fn alpm_option_remove_assumeinstalled(handle: ?*alpm_handle_t, dep: [*c]const alpm_depend_t) c_int;
pub extern fn alpm_option_get_physical_architectures(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_option_get_architectures(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_option_add_architecture(handle: ?*alpm_handle_t, arch: [*c]const u8) c_int;
pub extern fn alpm_option_set_architectures(handle: ?*alpm_handle_t, arches: [*c]alpm_list_t) c_int;
pub extern fn alpm_option_remove_architecture(handle: ?*alpm_handle_t, arch: [*c]const u8) c_int;
pub extern fn alpm_option_get_checkspace(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_option_set_checkspace(handle: ?*alpm_handle_t, checkspace: c_int) c_int;
pub extern fn alpm_option_get_dbext(handle: ?*alpm_handle_t) [*c]const u8;
pub extern fn alpm_option_set_dbext(handle: ?*alpm_handle_t, dbext: [*c]const u8) c_int;
pub extern fn alpm_option_get_default_siglevel(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_option_set_default_siglevel(handle: ?*alpm_handle_t, level: c_int) c_int;
pub extern fn alpm_option_get_local_file_siglevel(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_option_set_local_file_siglevel(handle: ?*alpm_handle_t, level: c_int) c_int;
pub extern fn alpm_option_get_remote_file_siglevel(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_option_set_remote_file_siglevel(handle: ?*alpm_handle_t, level: c_int) c_int;
pub extern fn alpm_option_get_disable_dl_timeout(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_option_set_disable_dl_timeout(handle: ?*alpm_handle_t, disable_dl_timeout: c_ushort) c_int;
pub extern fn alpm_option_get_parallel_downloads(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_option_set_parallel_downloads(handle: ?*alpm_handle_t, num_streams: c_uint) c_int;
pub extern fn alpm_option_get_disable_sandbox(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_option_set_disable_sandbox(handle: ?*alpm_handle_t, disable_sandbox: c_ushort) c_int;
pub extern fn alpm_option_get_disable_sandbox_filesystem(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_option_set_disable_sandbox_filesystem(handle: ?*alpm_handle_t, disable_sandbox_filesystem: c_ushort) c_int;
pub extern fn alpm_option_get_disable_sandbox_syscalls(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_option_set_disable_sandbox_syscalls(handle: ?*alpm_handle_t, disable_sandbox_syscalls: c_ushort) c_int;
pub extern fn alpm_option_get_disable_sandbox_network(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_option_set_disable_sandbox_network(handle: ?*alpm_handle_t, disable_sandbox_network: c_ushort) c_int;
pub const ALPM_PKG_REASON_EXPLICIT: c_int = 0;
pub const ALPM_PKG_REASON_DEPEND: c_int = 1;
pub const ALPM_PKG_REASON_UNKNOWN: c_int = 2;
pub const enum__alpm_pkgreason_t = c_uint;
pub const alpm_pkgreason_t = enum__alpm_pkgreason_t;
pub const ALPM_PKG_FROM_FILE: c_int = 1;
pub const ALPM_PKG_FROM_LOCALDB: c_int = 2;
pub const ALPM_PKG_FROM_SYNCDB: c_int = 3;
pub const enum__alpm_pkgfrom_t = c_uint;
pub const alpm_pkgfrom_t = enum__alpm_pkgfrom_t;
pub const ALPM_PKG_VALIDATION_UNKNOWN: c_int = 0;
pub const ALPM_PKG_VALIDATION_NONE: c_int = 1;
pub const ALPM_PKG_VALIDATION_MD5SUM: c_int = 2;
pub const ALPM_PKG_VALIDATION_SHA256SUM: c_int = 4;
pub const ALPM_PKG_VALIDATION_SIGNATURE: c_int = 8;
pub const enum__alpm_pkgvalidation_t = c_uint;
pub const alpm_pkgvalidation_t = enum__alpm_pkgvalidation_t;
pub extern fn alpm_pkg_load(handle: ?*alpm_handle_t, filename: [*c]const u8, full: c_int, level: c_int, pkg: [*c]?*alpm_pkg_t) c_int;
pub extern fn alpm_fetch_pkgurl(handle: ?*alpm_handle_t, urls: [*c]const alpm_list_t, fetched: [*c][*c]alpm_list_t) c_int;
pub extern fn alpm_pkg_find(haystack: [*c]alpm_list_t, needle: [*c]const u8) ?*alpm_pkg_t;
pub extern fn alpm_pkg_free(pkg: ?*alpm_pkg_t) c_int;
pub extern fn alpm_pkg_checkmd5sum(pkg: ?*alpm_pkg_t) c_int;
pub extern fn alpm_pkg_vercmp(a: [*c]const u8, b: [*c]const u8) c_int;
pub extern fn alpm_pkg_compute_requiredby(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_compute_optionalfor(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_should_ignore(handle: ?*alpm_handle_t, pkg: ?*alpm_pkg_t) c_int;
pub extern fn alpm_pkg_get_handle(pkg: ?*alpm_pkg_t) ?*alpm_handle_t;
pub extern fn alpm_pkg_get_filename(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_base(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_name(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_version(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_origin(pkg: ?*alpm_pkg_t) alpm_pkgfrom_t;
pub extern fn alpm_pkg_get_installed_db(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_desc(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_url(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_builddate(pkg: ?*alpm_pkg_t) alpm_time_t;
pub extern fn alpm_pkg_get_installdate(pkg: ?*alpm_pkg_t) alpm_time_t;
pub extern fn alpm_pkg_get_packager(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_md5sum(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_sha256sum(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_arch(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_size(pkg: ?*alpm_pkg_t) off_t;
pub extern fn alpm_pkg_get_isize(pkg: ?*alpm_pkg_t) off_t;
pub extern fn alpm_pkg_get_reason(pkg: ?*alpm_pkg_t) alpm_pkgreason_t;
pub extern fn alpm_pkg_get_licenses(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_get_groups(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_get_depends(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_get_optdepends(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_get_checkdepends(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_get_makedepends(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_get_conflicts(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_get_provides(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_get_replaces(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_get_files(pkg: ?*alpm_pkg_t) [*c]alpm_filelist_t;
pub extern fn alpm_pkg_get_backup(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_get_db(pkg: ?*alpm_pkg_t) ?*alpm_db_t;
pub extern fn alpm_pkg_get_base64_sig(pkg: ?*alpm_pkg_t) [*c]const u8;
pub extern fn alpm_pkg_get_sig(pkg: ?*alpm_pkg_t, sig: [*c][*c]u8, sig_len: [*c]usize) c_int;
pub extern fn alpm_pkg_get_validation(pkg: ?*alpm_pkg_t) c_int;
pub extern fn alpm_pkg_get_xdata(pkg: ?*alpm_pkg_t) [*c]alpm_list_t;
pub extern fn alpm_pkg_has_scriptlet(pkg: ?*alpm_pkg_t) c_int;
pub extern fn alpm_pkg_download_size(newpkg: ?*alpm_pkg_t) off_t;
pub extern fn alpm_pkg_set_reason(pkg: ?*alpm_pkg_t, reason: alpm_pkgreason_t) c_int;
pub extern fn alpm_pkg_changelog_open(pkg: ?*alpm_pkg_t) ?*anyopaque;
pub extern fn alpm_pkg_changelog_read(ptr: ?*anyopaque, size: usize, pkg: ?*const alpm_pkg_t, fp: ?*anyopaque) usize;
pub extern fn alpm_pkg_changelog_close(pkg: ?*const alpm_pkg_t, fp: ?*anyopaque) c_int;
pub extern fn alpm_pkg_mtree_open(pkg: ?*alpm_pkg_t) ?*struct_archive;
pub extern fn alpm_pkg_mtree_next(pkg: ?*const alpm_pkg_t, archive: ?*struct_archive, entry: [*c]?*struct_archive_entry) c_int;
pub extern fn alpm_pkg_mtree_close(pkg: ?*const alpm_pkg_t, archive: ?*struct_archive) c_int;
pub const ALPM_TRANS_FLAG_NODEPS: c_int = 1;
pub const ALPM_TRANS_FLAG_NOSAVE: c_int = 4;
pub const ALPM_TRANS_FLAG_NODEPVERSION: c_int = 8;
pub const ALPM_TRANS_FLAG_CASCADE: c_int = 16;
pub const ALPM_TRANS_FLAG_RECURSE: c_int = 32;
pub const ALPM_TRANS_FLAG_DBONLY: c_int = 64;
pub const ALPM_TRANS_FLAG_NOHOOKS: c_int = 128;
pub const ALPM_TRANS_FLAG_ALLDEPS: c_int = 256;
pub const ALPM_TRANS_FLAG_DOWNLOADONLY: c_int = 512;
pub const ALPM_TRANS_FLAG_NOSCRIPTLET: c_int = 1024;
pub const ALPM_TRANS_FLAG_NOCONFLICTS: c_int = 2048;
pub const ALPM_TRANS_FLAG_NEEDED: c_int = 8192;
pub const ALPM_TRANS_FLAG_ALLEXPLICIT: c_int = 16384;
pub const ALPM_TRANS_FLAG_UNNEEDED: c_int = 32768;
pub const ALPM_TRANS_FLAG_RECURSEALL: c_int = 65536;
pub const ALPM_TRANS_FLAG_NOLOCK: c_int = 131072;
pub const enum__alpm_transflag_t = c_uint;
pub const alpm_transflag_t = enum__alpm_transflag_t;
pub extern fn alpm_trans_get_flags(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_trans_get_add(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_trans_get_remove(handle: ?*alpm_handle_t) [*c]alpm_list_t;
pub extern fn alpm_trans_init(handle: ?*alpm_handle_t, flags: c_int) c_int;
pub extern fn alpm_trans_prepare(handle: ?*alpm_handle_t, data: [*c][*c]alpm_list_t) c_int;
pub extern fn alpm_trans_commit(handle: ?*alpm_handle_t, data: [*c][*c]alpm_list_t) c_int;
pub extern fn alpm_trans_interrupt(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_trans_release(handle: ?*alpm_handle_t) c_int;
pub extern fn alpm_sync_sysupgrade(handle: ?*alpm_handle_t, enable_downgrade: c_int) c_int;
pub extern fn alpm_add_pkg(handle: ?*alpm_handle_t, pkg: ?*alpm_pkg_t) c_int;
pub extern fn alpm_remove_pkg(handle: ?*alpm_handle_t, pkg: ?*alpm_pkg_t) c_int;
pub extern fn alpm_sync_get_new_version(pkg: ?*alpm_pkg_t, dbs_sync: [*c]alpm_list_t) ?*alpm_pkg_t;
pub extern fn alpm_compute_md5sum(filename: [*c]const u8) [*c]u8;
pub extern fn alpm_compute_sha256sum(filename: [*c]const u8) [*c]u8;
pub extern fn alpm_unlock(handle: ?*alpm_handle_t) c_int;
pub const ALPM_CAPABILITY_NLS: c_int = 1;
pub const ALPM_CAPABILITY_DOWNLOADER: c_int = 2;
pub const ALPM_CAPABILITY_SIGNATURES: c_int = 4;
pub const enum_alpm_caps = c_uint;
pub extern fn alpm_version() [*c]const u8;
pub extern fn alpm_capabilities() c_int;
pub extern fn alpm_sandbox_setup_child(handle: ?*alpm_handle_t, sandboxuser: [*c]const u8, sandbox_path: [*c]const u8, restrict_syscalls: bool) c_int;

pub const __VERSION__ = "Aro aro-zig";
pub const __Aro__ = "";
pub const __STDC__ = @as(c_int, 1);
pub const __STDC_HOSTED__ = @as(c_int, 1);
pub const __STDC_UTF_16__ = @as(c_int, 1);
pub const __STDC_UTF_32__ = @as(c_int, 1);
pub const __STDC_EMBED_NOT_FOUND__ = @as(c_int, 0);
pub const __STDC_EMBED_FOUND__ = @as(c_int, 1);
pub const __STDC_EMBED_EMPTY__ = @as(c_int, 2);
pub const __STDC_VERSION__ = @as(c_long, 201710);
pub const __GNUC__ = @as(c_int, 7);
pub const __GNUC_MINOR__ = @as(c_int, 1);
pub const __GNUC_PATCHLEVEL__ = @as(c_int, 0);
pub const __ARO_EMULATE_NO__ = @as(c_int, 0);
pub const __ARO_EMULATE_CLANG__ = @as(c_int, 1);
pub const __ARO_EMULATE_GCC__ = @as(c_int, 2);
pub const __ARO_EMULATE_MSVC__ = @as(c_int, 3);
pub const __ARO_EMULATE__ = __ARO_EMULATE_GCC__;
pub inline fn __building_module(x: anytype) @TypeOf(@as(c_int, 0)) {
    _ = &x;
    return @as(c_int, 0);
}
pub const linux = @as(c_int, 1);
pub const __linux = @as(c_int, 1);
pub const __linux__ = @as(c_int, 1);
pub const unix = @as(c_int, 1);
pub const __unix = @as(c_int, 1);
pub const __unix__ = @as(c_int, 1);
pub const __code_model_small__ = @as(c_int, 1);
pub const __amd64__ = @as(c_int, 1);
pub const __amd64 = @as(c_int, 1);
pub const __x86_64__ = @as(c_int, 1);
pub const __x86_64 = @as(c_int, 1);
pub const __SEG_GS = @as(c_int, 1);
pub const __SEG_FS = @as(c_int, 1);
pub const __seg_gs = @compileError("unable to translate macro: undefined identifier `address_space`"); // <builtin>:33:9
pub const __seg_fs = @compileError("unable to translate macro: undefined identifier `address_space`"); // <builtin>:34:9
pub const __LAHF_SAHF__ = @as(c_int, 1);
pub const __AES__ = @as(c_int, 1);
pub const __VAES__ = @as(c_int, 1);
pub const __PCLMUL__ = @as(c_int, 1);
pub const __VPCLMULQDQ__ = @as(c_int, 1);
pub const __LZCNT__ = @as(c_int, 1);
pub const __RDRND__ = @as(c_int, 1);
pub const __FSGSBASE__ = @as(c_int, 1);
pub const __BMI__ = @as(c_int, 1);
pub const __BMI2__ = @as(c_int, 1);
pub const __POPCNT__ = @as(c_int, 1);
pub const __PRFCHW__ = @as(c_int, 1);
pub const __RDSEED__ = @as(c_int, 1);
pub const __ADX__ = @as(c_int, 1);
pub const __MWAITX__ = @as(c_int, 1);
pub const __MOVBE__ = @as(c_int, 1);
pub const __SSE4A__ = @as(c_int, 1);
pub const __FMA__ = @as(c_int, 1);
pub const __F16C__ = @as(c_int, 1);
pub const __GFNI__ = @as(c_int, 1);
pub const __EVEX512__ = @as(c_int, 1);
pub const __AVX512CD__ = @as(c_int, 1);
pub const __AVX512VPOPCNTDQ__ = @as(c_int, 1);
pub const __AVX512VNNI__ = @as(c_int, 1);
pub const __AVX512BF16__ = @as(c_int, 1);
pub const __AVX512DQ__ = @as(c_int, 1);
pub const __AVX512BITALG__ = @as(c_int, 1);
pub const __AVX512BW__ = @as(c_int, 1);
pub const __AVX512VL__ = @as(c_int, 1);
pub const __EVEX256__ = @as(c_int, 1);
pub const __AVX512VBMI__ = @as(c_int, 1);
pub const __AVX512VBMI2__ = @as(c_int, 1);
pub const __AVX512IFMA__ = @as(c_int, 1);
pub const __AVX512VP2INTERSECT__ = @as(c_int, 1);
pub const __SHA__ = @as(c_int, 1);
pub const __FXSR__ = @as(c_int, 1);
pub const __XSAVE__ = @as(c_int, 1);
pub const __XSAVEOPT__ = @as(c_int, 1);
pub const __XSAVEC__ = @as(c_int, 1);
pub const __XSAVES__ = @as(c_int, 1);
pub const __PKU__ = @as(c_int, 1);
pub const __CLFLUSHOPT__ = @as(c_int, 1);
pub const __CLWB__ = @as(c_int, 1);
pub const __WBNOINVD__ = @as(c_int, 1);
pub const __SHSTK__ = @as(c_int, 1);
pub const __CLZERO__ = @as(c_int, 1);
pub const __RDPID__ = @as(c_int, 1);
pub const __RDPRU__ = @as(c_int, 1);
pub const __MOVDIRI__ = @as(c_int, 1);
pub const __MOVDIR64B__ = @as(c_int, 1);
pub const __INVPCID__ = @as(c_int, 1);
pub const __AVXVNNI__ = @as(c_int, 1);
pub const __CRC32__ = @as(c_int, 1);
pub const __AVX512F__ = @as(c_int, 1);
pub const __AVX2__ = @as(c_int, 1);
pub const __AVX__ = @as(c_int, 1);
pub const __SSE4_2__ = @as(c_int, 1);
pub const __SSE4_1__ = @as(c_int, 1);
pub const __SSSE3__ = @as(c_int, 1);
pub const __SSE3__ = @as(c_int, 1);
pub const __SSE2__ = @as(c_int, 1);
pub const __SSE__ = @as(c_int, 1);
pub const __SSE_MATH__ = @as(c_int, 1);
pub const __MMX__ = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 = @as(c_int, 1);
pub const __SIZEOF_FLOAT128__ = @as(c_int, 16);
pub const _LP64 = @as(c_int, 1);
pub const __LP64__ = @as(c_int, 1);
pub const __FLOAT128__ = @as(c_int, 1);
pub const __ORDER_LITTLE_ENDIAN__ = @as(c_int, 1234);
pub const __ORDER_BIG_ENDIAN__ = @as(c_int, 4321);
pub const __ORDER_PDP_ENDIAN__ = @as(c_int, 3412);
pub const __BYTE_ORDER__ = __ORDER_LITTLE_ENDIAN__;
pub const __LITTLE_ENDIAN__ = @as(c_int, 1);
pub const __ELF__ = @as(c_int, 1);
pub const __ATOMIC_RELAXED = @as(c_int, 0);
pub const __ATOMIC_CONSUME = @as(c_int, 1);
pub const __ATOMIC_ACQUIRE = @as(c_int, 2);
pub const __ATOMIC_RELEASE = @as(c_int, 3);
pub const __ATOMIC_ACQ_REL = @as(c_int, 4);
pub const __ATOMIC_SEQ_CST = @as(c_int, 5);
pub const __ATOMIC_BOOL_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR16_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR32_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WCHAR_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WINT_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_SHORT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_INT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LLONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_POINTER_LOCK_FREE = @as(c_int, 1);
pub const __WINT_UNSIGNED__ = @as(c_int, 1);
pub const __CHAR_BIT__ = @as(c_int, 8);
pub const __BOOL_WIDTH__ = @as(c_int, 8);
pub const __SCHAR_MAX__ = @as(c_int, 127);
pub const __SCHAR_WIDTH__ = @as(c_int, 8);
pub const __SHRT_MAX__ = @as(c_int, 32767);
pub const __SHRT_WIDTH__ = @as(c_int, 16);
pub const __INT_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_WIDTH__ = @as(c_int, 32);
pub const __LONG_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __LONG_WIDTH__ = @as(c_int, 64);
pub const __LONG_LONG_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __LONG_LONG_WIDTH__ = @as(c_int, 64);
pub const __WCHAR_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __WCHAR_WIDTH__ = @as(c_int, 32);
pub const __WINT_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __WINT_WIDTH__ = @as(c_int, 32);
pub const __INTMAX_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INTMAX_WIDTH__ = @as(c_int, 64);
pub const __SIZE_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __SIZE_WIDTH__ = @as(c_int, 64);
pub const __UINTMAX_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __UINTMAX_WIDTH__ = @as(c_int, 64);
pub const __PTRDIFF_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __PTRDIFF_WIDTH__ = @as(c_int, 64);
pub const __INTPTR_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INTPTR_WIDTH__ = @as(c_int, 64);
pub const __UINTPTR_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __UINTPTR_WIDTH__ = @as(c_int, 64);
pub const __SIG_ATOMIC_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __SIG_ATOMIC_WIDTH__ = @as(c_int, 32);
pub const __BITINT_MAXWIDTH__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __SIZEOF_FLOAT__ = @as(c_int, 4);
pub const __SIZEOF_DOUBLE__ = @as(c_int, 8);
pub const __SIZEOF_LONG_DOUBLE__ = @as(c_int, 10);
pub const __SIZEOF_SHORT__ = @as(c_int, 2);
pub const __SIZEOF_INT__ = @as(c_int, 4);
pub const __SIZEOF_LONG__ = @as(c_int, 8);
pub const __SIZEOF_LONG_LONG__ = @as(c_int, 8);
pub const __SIZEOF_POINTER__ = @as(c_int, 8);
pub const __SIZEOF_PTRDIFF_T__ = @as(c_int, 8);
pub const __SIZEOF_SIZE_T__ = @as(c_int, 8);
pub const __SIZEOF_WCHAR_T__ = @as(c_int, 4);
pub const __SIZEOF_WINT_T__ = @as(c_int, 4);
pub const __SIZEOF_INT128__ = @as(c_int, 16);
pub const __INTPTR_TYPE__ = c_long;
pub const __UINTPTR_TYPE__ = c_ulong;
pub const __INTMAX_TYPE__ = c_long;
pub const __INTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `L`"); // <builtin>:176:9
pub const __INTMAX_C = __helpers.L_SUFFIX;
pub const __UINTMAX_TYPE__ = c_ulong;
pub const __UINTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `UL`"); // <builtin>:179:9
pub const __UINTMAX_C = __helpers.UL_SUFFIX;
pub const __PTRDIFF_TYPE__ = c_long;
pub const __SIZE_TYPE__ = c_ulong;
pub const __WCHAR_TYPE__ = c_int;
pub const __WINT_TYPE__ = c_uint;
pub const __CHAR16_TYPE__ = c_ushort;
pub const __CHAR32_TYPE__ = c_uint;
pub const __INT8_TYPE__ = i8;
pub const __INT8_FMTd__ = "hhd";
pub const __INT8_FMTi__ = "hhi";
pub const __INT8_C_SUFFIX__ = "";
pub inline fn __INT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT16_TYPE__ = c_short;
pub const __INT16_FMTd__ = "hd";
pub const __INT16_FMTi__ = "hi";
pub const __INT16_C_SUFFIX__ = "";
pub inline fn __INT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT32_TYPE__ = c_int;
pub const __INT32_FMTd__ = "d";
pub const __INT32_FMTi__ = "i";
pub const __INT32_C_SUFFIX__ = "";
pub inline fn __INT32_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT64_TYPE__ = c_long;
pub const __INT64_FMTd__ = "ld";
pub const __INT64_FMTi__ = "li";
pub const __INT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `L`"); // <builtin>:205:9
pub const __UINT8_TYPE__ = u8;
pub const __UINT8_FMTo__ = "hho";
pub const __UINT8_FMTu__ = "hhu";
pub const __UINT8_FMTx__ = "hhx";
pub const __UINT8_FMTX__ = "hhX";
pub const __UINT8_C_SUFFIX__ = "";
pub inline fn __UINT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT8_MAX__ = @as(c_int, 255);
pub const __INT8_MAX__ = @as(c_int, 127);
pub const __UINT16_TYPE__ = c_ushort;
pub const __UINT16_FMTo__ = "ho";
pub const __UINT16_FMTu__ = "hu";
pub const __UINT16_FMTx__ = "hx";
pub const __UINT16_FMTX__ = "hX";
pub const __UINT16_C_SUFFIX__ = "";
pub inline fn __UINT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __INT16_MAX__ = @as(c_int, 32767);
pub const __UINT32_TYPE__ = c_uint;
pub const __UINT32_FMTo__ = "o";
pub const __UINT32_FMTu__ = "u";
pub const __UINT32_FMTx__ = "x";
pub const __UINT32_FMTX__ = "X";
pub const __UINT32_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `U`"); // <builtin>:230:9
pub const __UINT32_C = __helpers.U_SUFFIX;
pub const __UINT32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __INT32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __UINT64_TYPE__ = c_ulong;
pub const __UINT64_FMTo__ = "lo";
pub const __UINT64_FMTu__ = "lu";
pub const __UINT64_FMTx__ = "lx";
pub const __UINT64_FMTX__ = "lX";
pub const __UINT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `UL`"); // <builtin>:239:9
pub const __UINT64_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const __INT64_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INT_LEAST8_TYPE__ = i8;
pub const __INT_LEAST8_MAX__ = @as(c_int, 127);
pub const __INT_LEAST8_WIDTH__ = @as(c_int, 8);
pub const INT_LEAST8_FMTd__ = "hhd";
pub const INT_LEAST8_FMTi__ = "hhi";
pub const __UINT_LEAST8_TYPE__ = u8;
pub const __UINT_LEAST8_MAX__ = @as(c_int, 255);
pub const UINT_LEAST8_FMTo__ = "hho";
pub const UINT_LEAST8_FMTu__ = "hhu";
pub const UINT_LEAST8_FMTx__ = "hhx";
pub const UINT_LEAST8_FMTX__ = "hhX";
pub const __INT_FAST8_TYPE__ = i8;
pub const __INT_FAST8_MAX__ = @as(c_int, 127);
pub const __INT_FAST8_WIDTH__ = @as(c_int, 8);
pub const INT_FAST8_FMTd__ = "hhd";
pub const INT_FAST8_FMTi__ = "hhi";
pub const __UINT_FAST8_TYPE__ = u8;
pub const __UINT_FAST8_MAX__ = @as(c_int, 255);
pub const UINT_FAST8_FMTo__ = "hho";
pub const UINT_FAST8_FMTu__ = "hhu";
pub const UINT_FAST8_FMTx__ = "hhx";
pub const UINT_FAST8_FMTX__ = "hhX";
pub const __INT_LEAST16_TYPE__ = c_short;
pub const __INT_LEAST16_MAX__ = @as(c_int, 32767);
pub const __INT_LEAST16_WIDTH__ = @as(c_int, 16);
pub const INT_LEAST16_FMTd__ = "hd";
pub const INT_LEAST16_FMTi__ = "hi";
pub const __UINT_LEAST16_TYPE__ = c_ushort;
pub const __UINT_LEAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_LEAST16_FMTo__ = "ho";
pub const UINT_LEAST16_FMTu__ = "hu";
pub const UINT_LEAST16_FMTx__ = "hx";
pub const UINT_LEAST16_FMTX__ = "hX";
pub const __INT_FAST16_TYPE__ = c_short;
pub const __INT_FAST16_MAX__ = @as(c_int, 32767);
pub const __INT_FAST16_WIDTH__ = @as(c_int, 16);
pub const INT_FAST16_FMTd__ = "hd";
pub const INT_FAST16_FMTi__ = "hi";
pub const __UINT_FAST16_TYPE__ = c_ushort;
pub const __UINT_FAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_FAST16_FMTo__ = "ho";
pub const UINT_FAST16_FMTu__ = "hu";
pub const UINT_FAST16_FMTx__ = "hx";
pub const UINT_FAST16_FMTX__ = "hX";
pub const __INT_LEAST32_TYPE__ = c_int;
pub const __INT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_LEAST32_WIDTH__ = @as(c_int, 32);
pub const INT_LEAST32_FMTd__ = "d";
pub const INT_LEAST32_FMTi__ = "i";
pub const __UINT_LEAST32_TYPE__ = c_uint;
pub const __UINT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_LEAST32_FMTo__ = "o";
pub const UINT_LEAST32_FMTu__ = "u";
pub const UINT_LEAST32_FMTx__ = "x";
pub const UINT_LEAST32_FMTX__ = "X";
pub const __INT_FAST32_TYPE__ = c_int;
pub const __INT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_FAST32_WIDTH__ = @as(c_int, 32);
pub const INT_FAST32_FMTd__ = "d";
pub const INT_FAST32_FMTi__ = "i";
pub const __UINT_FAST32_TYPE__ = c_uint;
pub const __UINT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_FAST32_FMTo__ = "o";
pub const UINT_FAST32_FMTu__ = "u";
pub const UINT_FAST32_FMTx__ = "x";
pub const UINT_FAST32_FMTX__ = "X";
pub const __INT_LEAST64_TYPE__ = c_long;
pub const __INT_LEAST64_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INT_LEAST64_WIDTH__ = @as(c_int, 64);
pub const INT_LEAST64_FMTd__ = "ld";
pub const INT_LEAST64_FMTi__ = "li";
pub const __UINT_LEAST64_TYPE__ = c_ulong;
pub const __UINT_LEAST64_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const UINT_LEAST64_FMTo__ = "lo";
pub const UINT_LEAST64_FMTu__ = "lu";
pub const UINT_LEAST64_FMTx__ = "lx";
pub const UINT_LEAST64_FMTX__ = "lX";
pub const __INT_FAST64_TYPE__ = c_long;
pub const __INT_FAST64_MAX__ = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const __INT_FAST64_WIDTH__ = @as(c_int, 64);
pub const INT_FAST64_FMTd__ = "ld";
pub const INT_FAST64_FMTi__ = "li";
pub const __UINT_FAST64_TYPE__ = c_ulong;
pub const __UINT_FAST64_MAX__ = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const UINT_FAST64_FMTo__ = "lo";
pub const UINT_FAST64_FMTu__ = "lu";
pub const UINT_FAST64_FMTx__ = "lx";
pub const UINT_FAST64_FMTX__ = "lX";
pub const __FLT16_DENORM_MIN__ = @as(f16, 5.9604644775390625e-8);
pub const __FLT16_HAS_DENORM__ = "";
pub const __FLT16_DIG__ = @as(c_int, 3);
pub const __FLT16_DECIMAL_DIG__ = @as(c_int, 5);
pub const __FLT16_EPSILON__ = @as(f16, 9.765625e-4);
pub const __FLT16_HAS_INFINITY__ = "";
pub const __FLT16_HAS_QUIET_NAN__ = "";
pub const __FLT16_MANT_DIG__ = @as(c_int, 11);
pub const __FLT16_MAX_10_EXP__ = @as(c_int, 4);
pub const __FLT16_MAX_EXP__ = @as(c_int, 16);
pub const __FLT16_MAX__ = @as(f16, 6.5504e+4);
pub const __FLT16_MIN_10_EXP__ = -@as(c_int, 4);
pub const __FLT16_MIN_EXP__ = -@as(c_int, 13);
pub const __FLT16_MIN__ = @as(f16, 6.103515625e-5);
pub const __FLT_DENORM_MIN__ = @as(f32, 1.40129846e-45);
pub const __FLT_HAS_DENORM__ = "";
pub const __FLT_DIG__ = @as(c_int, 6);
pub const __FLT_DECIMAL_DIG__ = @as(c_int, 9);
pub const __FLT_EPSILON__ = @as(f32, 1.19209290e-7);
pub const __FLT_HAS_INFINITY__ = "";
pub const __FLT_HAS_QUIET_NAN__ = "";
pub const __FLT_MANT_DIG__ = @as(c_int, 24);
pub const __FLT_MAX_10_EXP__ = @as(c_int, 38);
pub const __FLT_MAX_EXP__ = @as(c_int, 128);
pub const __FLT_MAX__ = @as(f32, 3.40282347e+38);
pub const __FLT_MIN_10_EXP__ = -@as(c_int, 37);
pub const __FLT_MIN_EXP__ = -@as(c_int, 125);
pub const __FLT_MIN__ = @as(f32, 1.17549435e-38);
pub const __DBL_DENORM_MIN__ = @as(f64, 4.9406564584124654e-324);
pub const __DBL_HAS_DENORM__ = "";
pub const __DBL_DIG__ = @as(c_int, 15);
pub const __DBL_DECIMAL_DIG__ = @as(c_int, 17);
pub const __DBL_EPSILON__ = @as(f64, 2.2204460492503131e-16);
pub const __DBL_HAS_INFINITY__ = "";
pub const __DBL_HAS_QUIET_NAN__ = "";
pub const __DBL_MANT_DIG__ = @as(c_int, 53);
pub const __DBL_MAX_10_EXP__ = @as(c_int, 308);
pub const __DBL_MAX_EXP__ = @as(c_int, 1024);
pub const __DBL_MAX__ = @as(f64, 1.7976931348623157e+308);
pub const __DBL_MIN_10_EXP__ = -@as(c_int, 307);
pub const __DBL_MIN_EXP__ = -@as(c_int, 1021);
pub const __DBL_MIN__ = @as(f64, 2.2250738585072014e-308);
pub const __LDBL_DENORM_MIN__ = @as(c_longdouble, 3.64519953188247460253e-4951);
pub const __LDBL_HAS_DENORM__ = "";
pub const __LDBL_DIG__ = @as(c_int, 18);
pub const __LDBL_DECIMAL_DIG__ = @as(c_int, 21);
pub const __LDBL_EPSILON__ = @as(c_longdouble, 1.08420217248550443401e-19);
pub const __LDBL_HAS_INFINITY__ = "";
pub const __LDBL_HAS_QUIET_NAN__ = "";
pub const __LDBL_MANT_DIG__ = @as(c_int, 64);
pub const __LDBL_MAX_10_EXP__ = @as(c_int, 4932);
pub const __LDBL_MAX_EXP__ = @as(c_int, 16384);
pub const __LDBL_MAX__ = @as(c_longdouble, 1.18973149535723176502e+4932);
pub const __LDBL_MIN_10_EXP__ = -@as(c_int, 4931);
pub const __LDBL_MIN_EXP__ = -@as(c_int, 16381);
pub const __LDBL_MIN__ = @as(c_longdouble, 3.36210314311209350626e-4932);
pub const __FLT_EVAL_METHOD__ = @as(c_int, 0);
pub const __FLT_RADIX__ = @as(c_int, 2);
pub const __DECIMAL_DIG__ = __LDBL_DECIMAL_DIG__;
pub const __pic__ = @as(c_int, 2);
pub const __PIC__ = @as(c_int, 2);
pub const __GLIBC_MINOR__ = @as(c_int, 43);
pub const ALPM_H = "";
pub const @"bool" = bool;
pub const @"true" = @as(c_int, 1);
pub const @"false" = @as(c_int, 0);
pub const __bool_true_false_are_defined = @as(c_int, 1);
pub const __CLANG_STDINT_H = "";
pub const _STDINT_H = @as(c_int, 1);
pub const _FEATURES_H = @as(c_int, 1);
pub const __KERNEL_STRICT_NAMES = "";
pub inline fn __GNUC_PREREQ(maj: anytype, min: anytype) @TypeOf(((__GNUC__ << @as(c_int, 16)) + __GNUC_MINOR__) >= ((maj << @as(c_int, 16)) + min)) {
    _ = &maj;
    _ = &min;
    return ((__GNUC__ << @as(c_int, 16)) + __GNUC_MINOR__) >= ((maj << @as(c_int, 16)) + min);
}
pub inline fn __glibc_clang_prereq(maj: anytype, min: anytype) @TypeOf(@as(c_int, 0)) {
    _ = &maj;
    _ = &min;
    return @as(c_int, 0);
}
pub const __GLIBC_USE = @compileError("unable to translate macro: undefined identifier `__GLIBC_USE_`"); // /usr/include/features.h:197:9
pub const _DEFAULT_SOURCE = @as(c_int, 1);
pub const __GLIBC_USE_ISOC2Y = @as(c_int, 0);
pub const __GLIBC_USE_ISOC23 = @as(c_int, 0);
pub const __USE_ISOC11 = @as(c_int, 1);
pub const __USE_POSIX_IMPLICITLY = @as(c_int, 1);
pub const _POSIX_SOURCE = @as(c_int, 1);
pub const _POSIX_C_SOURCE = @as(c_long, 202405);
pub const __USE_POSIX = @as(c_int, 1);
pub const __USE_POSIX2 = @as(c_int, 1);
pub const __USE_POSIX199309 = @as(c_int, 1);
pub const __USE_POSIX199506 = @as(c_int, 1);
pub const __USE_XOPEN2K = @as(c_int, 1);
pub const __USE_ISOC95 = @as(c_int, 1);
pub const __USE_ISOC99 = @as(c_int, 1);
pub const __USE_XOPEN2K8 = @as(c_int, 1);
pub const _ATFILE_SOURCE = @as(c_int, 1);
pub const __USE_XOPEN2K24 = @as(c_int, 1);
pub const __WORDSIZE = @as(c_int, 64);
pub const __WORDSIZE_TIME64_COMPAT32 = @as(c_int, 1);
pub const __SYSCALL_WORDSIZE = @as(c_int, 64);
pub const __TIMESIZE = __WORDSIZE;
pub const __USE_TIME_BITS64 = @as(c_int, 1);
pub const __USE_MISC = @as(c_int, 1);
pub const __USE_ATFILE = @as(c_int, 1);
pub const __USE_FORTIFY_LEVEL = @as(c_int, 0);
pub const __GLIBC_USE_DEPRECATED_GETS = @as(c_int, 0);
pub const __GLIBC_USE_DEPRECATED_SCANF = @as(c_int, 0);
pub const __GLIBC_USE_C23_STRTOL = @as(c_int, 0);
pub const _STDC_PREDEF_H = @as(c_int, 1);
pub const __STDC_IEC_559__ = @as(c_int, 1);
pub const __STDC_IEC_60559_BFP__ = @as(c_long, 201404);
pub const __STDC_IEC_559_COMPLEX__ = @as(c_int, 1);
pub const __STDC_IEC_60559_COMPLEX__ = @as(c_long, 201404);
pub const __STDC_ISO_10646__ = @as(c_long, 201706);
pub const __GNU_LIBRARY__ = @as(c_int, 6);
pub const __GLIBC__ = @as(c_int, 2);
pub inline fn __GLIBC_PREREQ(maj: anytype, min: anytype) @TypeOf(((__GLIBC__ << @as(c_int, 16)) + __GLIBC_MINOR__) >= ((maj << @as(c_int, 16)) + min)) {
    _ = &maj;
    _ = &min;
    return ((__GLIBC__ << @as(c_int, 16)) + __GLIBC_MINOR__) >= ((maj << @as(c_int, 16)) + min);
}
pub const _SYS_CDEFS_H = @as(c_int, 1);
pub const __glibc_has_attribute = @compileError("unable to translate macro: undefined identifier `__has_attribute`"); // /usr/include/sys/cdefs.h:45:10
pub inline fn __glibc_has_builtin(name: anytype) @TypeOf(__builtin.has_builtin(name)) {
    _ = &name;
    return __builtin.has_builtin(name);
}
pub const __glibc_has_extension = @compileError("unable to translate macro: undefined identifier `__has_extension`"); // /usr/include/sys/cdefs.h:55:10
pub const __LEAF = @compileError("unable to translate macro: undefined identifier `__leaf__`"); // /usr/include/sys/cdefs.h:65:11
pub const __LEAF_ATTR = @compileError("unable to translate macro: undefined identifier `__leaf__`"); // /usr/include/sys/cdefs.h:66:11
pub const __THROW = @compileError("unable to translate macro: undefined identifier `__nothrow__`"); // /usr/include/sys/cdefs.h:79:11
pub const __THROWNL = @compileError("unable to translate macro: undefined identifier `__nothrow__`"); // /usr/include/sys/cdefs.h:80:11
pub const __NTH = @compileError("unable to translate macro: undefined identifier `__nothrow__`"); // /usr/include/sys/cdefs.h:81:11
pub const __NTHNL = @compileError("unable to translate macro: undefined identifier `__nothrow__`"); // /usr/include/sys/cdefs.h:82:11
pub const __COLD = @compileError("unable to translate macro: undefined identifier `__cold__`"); // /usr/include/sys/cdefs.h:102:11
pub inline fn __P(args: anytype) @TypeOf(args) {
    _ = &args;
    return args;
}
pub inline fn __PMT(args: anytype) @TypeOf(args) {
    _ = &args;
    return args;
}
pub const __CONCAT = @compileError("unable to translate C expr: unexpected token '##'"); // /usr/include/sys/cdefs.h:131:9
pub const __STRING = @compileError("unable to translate C expr: unexpected token ''"); // /usr/include/sys/cdefs.h:132:9
pub const __ptr_t = ?*anyopaque;
pub const __BEGIN_DECLS = "";
pub const __END_DECLS = "";
pub const __attribute_overloadable__ = "";
pub inline fn __bos(ptr: anytype) @TypeOf(__builtin.object_size(ptr, __USE_FORTIFY_LEVEL > @as(c_int, 1))) {
    _ = &ptr;
    return __builtin.object_size(ptr, __USE_FORTIFY_LEVEL > @as(c_int, 1));
}
pub inline fn __bos0(ptr: anytype) @TypeOf(__builtin.object_size(ptr, @as(c_int, 0))) {
    _ = &ptr;
    return __builtin.object_size(ptr, @as(c_int, 0));
}
pub inline fn __glibc_objsize0(__o: anytype) @TypeOf(__bos0(__o)) {
    _ = &__o;
    return __bos0(__o);
}
pub inline fn __glibc_objsize(__o: anytype) @TypeOf(__bos(__o)) {
    _ = &__o;
    return __bos(__o);
}
pub const __warnattr = @compileError("unable to translate macro: undefined identifier `__warning__`"); // /usr/include/sys/cdefs.h:366:10
pub const __errordecl = @compileError("unable to translate macro: undefined identifier `__error__`"); // /usr/include/sys/cdefs.h:367:10
pub const __flexarr = @compileError("unable to translate C expr: unexpected token '['"); // /usr/include/sys/cdefs.h:379:10
pub const __glibc_c99_flexarr_available = @as(c_int, 1);
pub const __REDIRECT = @compileError("unable to translate C expr: unexpected token '__asm__'"); // /usr/include/sys/cdefs.h:410:10
pub const __REDIRECT_NTH = @compileError("unable to translate C expr: unexpected token '__asm__'"); // /usr/include/sys/cdefs.h:417:11
pub const __REDIRECT_NTHNL = @compileError("unable to translate C expr: unexpected token '__asm__'"); // /usr/include/sys/cdefs.h:419:11
pub const __ASMNAME = @compileError("unable to translate macro: undefined identifier `__USER_LABEL_PREFIX__`"); // /usr/include/sys/cdefs.h:422:10
pub inline fn __ASMNAME2(prefix: anytype, cname: anytype) @TypeOf(__STRING(prefix) ++ cname) {
    _ = &prefix;
    _ = &cname;
    return __STRING(prefix) ++ cname;
}
pub const __REDIRECT_FORTIFY = __REDIRECT;
pub const __REDIRECT_FORTIFY_NTH = __REDIRECT_NTH;
pub const __attribute_malloc__ = @compileError("unable to translate macro: undefined identifier `__malloc__`"); // /usr/include/sys/cdefs.h:452:10
pub const __attribute_alloc_size__ = @compileError("unable to translate macro: undefined identifier `__alloc_size__`"); // /usr/include/sys/cdefs.h:460:10
pub const __attribute_alloc_align__ = @compileError("unable to translate macro: undefined identifier `__alloc_align__`"); // /usr/include/sys/cdefs.h:469:10
pub const __attribute_pure__ = @compileError("unable to translate macro: undefined identifier `__pure__`"); // /usr/include/sys/cdefs.h:479:10
pub const __attribute_const__ = @compileError("unable to translate C expr: unexpected token '__attribute__'"); // /usr/include/sys/cdefs.h:486:10
pub const __attribute_maybe_unused__ = @compileError("unable to translate macro: undefined identifier `__unused__`"); // /usr/include/sys/cdefs.h:492:10
pub const __attribute_used__ = @compileError("unable to translate macro: undefined identifier `__used__`"); // /usr/include/sys/cdefs.h:501:10
pub const __attribute_noinline__ = @compileError("unable to translate macro: undefined identifier `__noinline__`"); // /usr/include/sys/cdefs.h:502:10
pub const __attribute_deprecated__ = @compileError("unable to translate macro: undefined identifier `__deprecated__`"); // /usr/include/sys/cdefs.h:510:10
pub const __attribute_deprecated_msg__ = @compileError("unable to translate macro: undefined identifier `__deprecated__`"); // /usr/include/sys/cdefs.h:520:10
pub const __attribute_format_arg__ = @compileError("unable to translate macro: undefined identifier `__format_arg__`"); // /usr/include/sys/cdefs.h:533:10
pub const __attribute_format_strfmon__ = @compileError("unable to translate macro: undefined identifier `__format__`"); // /usr/include/sys/cdefs.h:543:10
pub const __attribute_nonnull__ = @compileError("unable to translate macro: undefined identifier `__nonnull__`"); // /usr/include/sys/cdefs.h:555:11
pub inline fn __nonnull(params: anytype) @TypeOf(__attribute_nonnull__(params)) {
    _ = &params;
    return __attribute_nonnull__(params);
}
pub const __returns_nonnull = @compileError("unable to translate macro: undefined identifier `__returns_nonnull__`"); // /usr/include/sys/cdefs.h:568:10
pub const __attribute_warn_unused_result__ = @compileError("unable to translate macro: undefined identifier `__warn_unused_result__`"); // /usr/include/sys/cdefs.h:577:10
pub const __wur = "";
pub const __always_inline = @compileError("unable to translate macro: undefined identifier `__always_inline__`"); // /usr/include/sys/cdefs.h:595:10
pub const __attribute_artificial__ = @compileError("unable to translate macro: undefined identifier `__artificial__`"); // /usr/include/sys/cdefs.h:604:10
pub const __extern_inline = @compileError("unable to translate C expr: unexpected token 'extern'"); // /usr/include/sys/cdefs.h:626:11
pub const __extern_always_inline = @compileError("unable to translate C expr: unexpected token 'extern'"); // /usr/include/sys/cdefs.h:627:11
pub const __fortify_function = __extern_always_inline ++ __attribute_artificial__;
pub const __va_arg_pack = @compileError("unable to translate macro: undefined identifier `__builtin_va_arg_pack`"); // /usr/include/sys/cdefs.h:638:10
pub const __va_arg_pack_len = @compileError("unable to translate macro: undefined identifier `__builtin_va_arg_pack_len`"); // /usr/include/sys/cdefs.h:639:10
pub const __restrict_arr = @compileError("unable to translate C expr: unexpected token '__restrict'"); // /usr/include/sys/cdefs.h:666:10
pub inline fn __glibc_unlikely(cond: anytype) @TypeOf(__builtin.expect(cond, @as(c_int, 0))) {
    _ = &cond;
    return __builtin.expect(cond, @as(c_int, 0));
}
pub inline fn __glibc_likely(cond: anytype) @TypeOf(__builtin.expect(cond, @as(c_int, 1))) {
    _ = &cond;
    return __builtin.expect(cond, @as(c_int, 1));
}
pub const __attribute_nonstring__ = "";
pub inline fn __attribute_copy__(arg: anytype) void {
    _ = &arg;
    return;
}
pub const __LDOUBLE_REDIRECTS_TO_FLOAT128_ABI = @as(c_int, 0);
pub inline fn __LDBL_REDIR1(name: anytype, proto: anytype, alias: anytype) @TypeOf(name ++ proto) {
    _ = &name;
    _ = &proto;
    _ = &alias;
    return name ++ proto;
}
pub inline fn __LDBL_REDIR(name: anytype, proto: anytype) @TypeOf(name ++ proto) {
    _ = &name;
    _ = &proto;
    return name ++ proto;
}
pub inline fn __LDBL_REDIR1_NTH(name: anytype, proto: anytype, alias: anytype) @TypeOf(name ++ proto ++ __THROW) {
    _ = &name;
    _ = &proto;
    _ = &alias;
    return name ++ proto ++ __THROW;
}
pub inline fn __LDBL_REDIR_NTH(name: anytype, proto: anytype) @TypeOf(name ++ proto ++ __THROW) {
    _ = &name;
    _ = &proto;
    return name ++ proto ++ __THROW;
}
pub inline fn __LDBL_REDIR2_DECL(name: anytype) void {
    _ = &name;
    return;
}
pub inline fn __LDBL_REDIR_DECL(name: anytype) void {
    _ = &name;
    return;
}
pub inline fn __REDIRECT_LDBL(name: anytype, proto: anytype, alias: anytype) @TypeOf(__REDIRECT(name, proto, alias)) {
    _ = &name;
    _ = &proto;
    _ = &alias;
    return __REDIRECT(name, proto, alias);
}
pub inline fn __REDIRECT_NTH_LDBL(name: anytype, proto: anytype, alias: anytype) @TypeOf(__REDIRECT_NTH(name, proto, alias)) {
    _ = &name;
    _ = &proto;
    _ = &alias;
    return __REDIRECT_NTH(name, proto, alias);
}
pub const __glibc_macro_warning1 = @compileError("unable to translate macro: undefined identifier `_Pragma`"); // /usr/include/sys/cdefs.h:807:10
pub const __glibc_macro_warning = @compileError("unable to translate macro: undefined identifier `GCC`"); // /usr/include/sys/cdefs.h:808:10
pub const __HAVE_GENERIC_SELECTION = @as(c_int, 1);
pub const __glibc_const_generic = @compileError("unable to translate C expr: expected type instead got 'const'"); // /usr/include/sys/cdefs.h:837:10
pub inline fn __fortified_attr_access(a: anytype, o: anytype, s: anytype) void {
    _ = &a;
    _ = &o;
    _ = &s;
    return;
}
pub inline fn __attr_access(x: anytype) void {
    _ = &x;
    return;
}
pub inline fn __attr_access_none(argno: anytype) void {
    _ = &argno;
    return;
}
pub inline fn __attr_dealloc(dealloc: anytype, argno: anytype) void {
    _ = &dealloc;
    _ = &argno;
    return;
}
pub const __attr_dealloc_free = "";
pub const __attribute_returns_twice__ = @compileError("unable to translate macro: undefined identifier `__returns_twice__`"); // /usr/include/sys/cdefs.h:884:10
pub const __attribute_struct_may_alias__ = @compileError("unable to translate macro: undefined identifier `__may_alias__`"); // /usr/include/sys/cdefs.h:893:10
pub const __stub___compat_bdflush = "";
pub const __stub_chflags = "";
pub const __stub_fchflags = "";
pub const __stub_gtty = "";
pub const __stub_revoke = "";
pub const __stub_setlogin = "";
pub const __stub_sigreturn = "";
pub const __stub_stty = "";
pub const _BITS_TYPES_H = @as(c_int, 1);
pub const __S16_TYPE = c_short;
pub const __U16_TYPE = c_ushort;
pub const __S32_TYPE = c_int;
pub const __U32_TYPE = c_uint;
pub const __SLONGWORD_TYPE = c_long;
pub const __ULONGWORD_TYPE = c_ulong;
pub const __SQUAD_TYPE = c_long;
pub const __UQUAD_TYPE = c_ulong;
pub const __SWORD_TYPE = c_long;
pub const __UWORD_TYPE = c_ulong;
pub const __SLONG32_TYPE = c_int;
pub const __ULONG32_TYPE = c_uint;
pub const __S64_TYPE = c_long;
pub const __U64_TYPE = c_ulong;
pub const _BITS_TYPESIZES_H = @as(c_int, 1);
pub const __SYSCALL_SLONG_TYPE = __SLONGWORD_TYPE;
pub const __SYSCALL_ULONG_TYPE = __ULONGWORD_TYPE;
pub const __DEV_T_TYPE = __UQUAD_TYPE;
pub const __UID_T_TYPE = __U32_TYPE;
pub const __GID_T_TYPE = __U32_TYPE;
pub const __INO_T_TYPE = __SYSCALL_ULONG_TYPE;
pub const __INO64_T_TYPE = __UQUAD_TYPE;
pub const __MODE_T_TYPE = __U32_TYPE;
pub const __NLINK_T_TYPE = __SYSCALL_ULONG_TYPE;
pub const __FSWORD_T_TYPE = __SYSCALL_SLONG_TYPE;
pub const __OFF_T_TYPE = __SYSCALL_SLONG_TYPE;
pub const __OFF64_T_TYPE = __SQUAD_TYPE;
pub const __PID_T_TYPE = __S32_TYPE;
pub const __RLIM_T_TYPE = __SYSCALL_ULONG_TYPE;
pub const __RLIM64_T_TYPE = __UQUAD_TYPE;
pub const __BLKCNT_T_TYPE = __SYSCALL_SLONG_TYPE;
pub const __BLKCNT64_T_TYPE = __SQUAD_TYPE;
pub const __FSBLKCNT_T_TYPE = __SYSCALL_ULONG_TYPE;
pub const __FSBLKCNT64_T_TYPE = __UQUAD_TYPE;
pub const __FSFILCNT_T_TYPE = __SYSCALL_ULONG_TYPE;
pub const __FSFILCNT64_T_TYPE = __UQUAD_TYPE;
pub const __ID_T_TYPE = __U32_TYPE;
pub const __CLOCK_T_TYPE = __SYSCALL_SLONG_TYPE;
pub const __TIME_T_TYPE = __SYSCALL_SLONG_TYPE;
pub const __USECONDS_T_TYPE = __U32_TYPE;
pub const __SUSECONDS_T_TYPE = __SYSCALL_SLONG_TYPE;
pub const __SUSECONDS64_T_TYPE = __SQUAD_TYPE;
pub const __DADDR_T_TYPE = __S32_TYPE;
pub const __KEY_T_TYPE = __S32_TYPE;
pub const __CLOCKID_T_TYPE = __S32_TYPE;
pub const __TIMER_T_TYPE = ?*anyopaque;
pub const __BLKSIZE_T_TYPE = __SYSCALL_SLONG_TYPE;
pub const __FSID_T_TYPE = @compileError("unable to translate macro: undefined identifier `__val`"); // /usr/include/bits/typesizes.h:73:9
pub const __SSIZE_T_TYPE = __SWORD_TYPE;
pub const __CPU_MASK_TYPE = __SYSCALL_ULONG_TYPE;
pub const __OFF_T_MATCHES_OFF64_T = @as(c_int, 1);
pub const __INO_T_MATCHES_INO64_T = @as(c_int, 1);
pub const __RLIM_T_MATCHES_RLIM64_T = @as(c_int, 1);
pub const __STATFS_MATCHES_STATFS64 = @as(c_int, 1);
pub const __KERNEL_OLD_TIMEVAL_MATCHES_TIMEVAL64 = @as(c_int, 1);
pub const __FD_SETSIZE = @as(c_int, 1024);
pub const _BITS_TIME64_H = @as(c_int, 1);
pub const __TIME64_T_TYPE = __TIME_T_TYPE;
pub const _BITS_WCHAR_H = @as(c_int, 1);
pub const __WCHAR_MAX = __WCHAR_MAX__;
pub const __WCHAR_MIN = -__WCHAR_MAX - @as(c_int, 1);
pub const _BITS_STDINT_INTN_H = @as(c_int, 1);
pub const _BITS_STDINT_UINTN_H = @as(c_int, 1);
pub const _BITS_STDINT_LEAST_H = @as(c_int, 1);
pub const __intptr_t_defined = "";
pub const __INT64_C = __helpers.L_SUFFIX;
pub const __UINT64_C = __helpers.UL_SUFFIX;
pub const INT8_MIN = -@as(c_int, 128);
pub const INT16_MIN = -@as(c_int, 32767) - @as(c_int, 1);
pub const INT32_MIN = -__helpers.promoteIntLiteral(c_int, 2147483647, .decimal) - @as(c_int, 1);
pub const INT64_MIN = -__INT64_C(__helpers.promoteIntLiteral(c_int, 9223372036854775807, .decimal)) - @as(c_int, 1);
pub const INT8_MAX = @as(c_int, 127);
pub const INT16_MAX = @as(c_int, 32767);
pub const INT32_MAX = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const INT64_MAX = __INT64_C(__helpers.promoteIntLiteral(c_int, 9223372036854775807, .decimal));
pub const UINT8_MAX = @as(c_int, 255);
pub const UINT16_MAX = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT32_MAX = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT64_MAX = __UINT64_C(__helpers.promoteIntLiteral(c_int, 18446744073709551615, .decimal));
pub const INT_LEAST8_MIN = -@as(c_int, 128);
pub const INT_LEAST16_MIN = -@as(c_int, 32767) - @as(c_int, 1);
pub const INT_LEAST32_MIN = -__helpers.promoteIntLiteral(c_int, 2147483647, .decimal) - @as(c_int, 1);
pub const INT_LEAST64_MIN = -__INT64_C(__helpers.promoteIntLiteral(c_int, 9223372036854775807, .decimal)) - @as(c_int, 1);
pub const INT_LEAST8_MAX = @as(c_int, 127);
pub const INT_LEAST16_MAX = @as(c_int, 32767);
pub const INT_LEAST32_MAX = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const INT_LEAST64_MAX = __INT64_C(__helpers.promoteIntLiteral(c_int, 9223372036854775807, .decimal));
pub const UINT_LEAST8_MAX = @as(c_int, 255);
pub const UINT_LEAST16_MAX = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_LEAST32_MAX = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_LEAST64_MAX = __UINT64_C(__helpers.promoteIntLiteral(c_int, 18446744073709551615, .decimal));
pub const INT_FAST8_MIN = -@as(c_int, 128);
pub const INT_FAST16_MIN = -__helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal) - @as(c_int, 1);
pub const INT_FAST32_MIN = -__helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal) - @as(c_int, 1);
pub const INT_FAST64_MIN = -__INT64_C(__helpers.promoteIntLiteral(c_int, 9223372036854775807, .decimal)) - @as(c_int, 1);
pub const INT_FAST8_MAX = @as(c_int, 127);
pub const INT_FAST16_MAX = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const INT_FAST32_MAX = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const INT_FAST64_MAX = __INT64_C(__helpers.promoteIntLiteral(c_int, 9223372036854775807, .decimal));
pub const UINT_FAST8_MAX = @as(c_int, 255);
pub const UINT_FAST16_MAX = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const UINT_FAST32_MAX = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const UINT_FAST64_MAX = __UINT64_C(__helpers.promoteIntLiteral(c_int, 18446744073709551615, .decimal));
pub const INTPTR_MIN = -__helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal) - @as(c_int, 1);
pub const INTPTR_MAX = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const UINTPTR_MAX = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const INTMAX_MIN = -__INT64_C(__helpers.promoteIntLiteral(c_int, 9223372036854775807, .decimal)) - @as(c_int, 1);
pub const INTMAX_MAX = __INT64_C(__helpers.promoteIntLiteral(c_int, 9223372036854775807, .decimal));
pub const UINTMAX_MAX = __UINT64_C(__helpers.promoteIntLiteral(c_int, 18446744073709551615, .decimal));
pub const PTRDIFF_MIN = -__helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal) - @as(c_int, 1);
pub const PTRDIFF_MAX = __helpers.promoteIntLiteral(c_long, 9223372036854775807, .decimal);
pub const SIG_ATOMIC_MIN = -__helpers.promoteIntLiteral(c_int, 2147483647, .decimal) - @as(c_int, 1);
pub const SIG_ATOMIC_MAX = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const SIZE_MAX = __helpers.promoteIntLiteral(c_ulong, 18446744073709551615, .decimal);
pub const WCHAR_MIN = __WCHAR_MIN;
pub const WCHAR_MAX = __WCHAR_MAX;
pub const WINT_MIN = @as(c_uint, 0);
pub const WINT_MAX = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub inline fn INT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub inline fn INT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub inline fn INT32_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const INT64_C = __helpers.L_SUFFIX;
pub inline fn UINT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub inline fn UINT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const UINT32_C = __helpers.U_SUFFIX;
pub const UINT64_C = __helpers.UL_SUFFIX;
pub const INTMAX_C = __helpers.L_SUFFIX;
pub const UINTMAX_C = __helpers.UL_SUFFIX;
pub const _SYS_TYPES_H = @as(c_int, 1);
pub const __u_char_defined = "";
pub const __ino_t_defined = "";
pub const __dev_t_defined = "";
pub const __gid_t_defined = "";
pub const __mode_t_defined = "";
pub const __nlink_t_defined = "";
pub const __uid_t_defined = "";
pub const __off_t_defined = "";
pub const __pid_t_defined = "";
pub const __id_t_defined = "";
pub const __ssize_t_defined = "";
pub const __daddr_t_defined = "";
pub const __key_t_defined = "";
pub const __clock_t_defined = @as(c_int, 1);
pub const __clockid_t_defined = @as(c_int, 1);
pub const __time_t_defined = @as(c_int, 1);
pub const __timer_t_defined = @as(c_int, 1);
pub const __need_size_t = "";
pub const __STDC_VERSION_STDDEF_H__ = @as(c_long, 202311);
pub const NULL = __helpers.cast(?*anyopaque, @as(c_int, 0));
pub const offsetof = @compileError("unable to translate macro: undefined identifier `__builtin_offsetof`"); // /usr/lib/zig/compiler/aro/include/stddef.h:18:9
pub const __BIT_TYPES_DEFINED__ = @as(c_int, 1);
pub const _ENDIAN_H = @as(c_int, 1);
pub const _BITS_ENDIAN_H = @as(c_int, 1);
pub const __LITTLE_ENDIAN = @as(c_int, 1234);
pub const __BIG_ENDIAN = @as(c_int, 4321);
pub const __PDP_ENDIAN = @as(c_int, 3412);
pub const _BITS_ENDIANNESS_H = @as(c_int, 1);
pub const __BYTE_ORDER = __LITTLE_ENDIAN;
pub const __FLOAT_WORD_ORDER = __BYTE_ORDER;
pub inline fn __LONG_LONG_PAIR(HI: anytype, LO: anytype) @TypeOf(HI) {
    _ = &HI;
    _ = &LO;
    return blk: {
        _ = &LO;
        break :blk HI;
    };
}
pub const LITTLE_ENDIAN = __LITTLE_ENDIAN;
pub const BIG_ENDIAN = __BIG_ENDIAN;
pub const PDP_ENDIAN = __PDP_ENDIAN;
pub const BYTE_ORDER = __BYTE_ORDER;
pub const _BITS_BYTESWAP_H = @as(c_int, 1);
pub inline fn __bswap_constant_16(x: anytype) __uint16_t {
    _ = &x;
    return __helpers.cast(__uint16_t, ((x >> @as(c_int, 8)) & @as(c_int, 0xff)) | ((x & @as(c_int, 0xff)) << @as(c_int, 8)));
}
pub inline fn __bswap_constant_32(x: anytype) @TypeOf(((((x & __helpers.promoteIntLiteral(c_uint, 0xff000000, .hex)) >> @as(c_int, 24)) | ((x & __helpers.promoteIntLiteral(c_uint, 0x00ff0000, .hex)) >> @as(c_int, 8))) | ((x & @as(c_uint, 0x0000ff00)) << @as(c_int, 8))) | ((x & @as(c_uint, 0x000000ff)) << @as(c_int, 24))) {
    _ = &x;
    return ((((x & __helpers.promoteIntLiteral(c_uint, 0xff000000, .hex)) >> @as(c_int, 24)) | ((x & __helpers.promoteIntLiteral(c_uint, 0x00ff0000, .hex)) >> @as(c_int, 8))) | ((x & @as(c_uint, 0x0000ff00)) << @as(c_int, 8))) | ((x & @as(c_uint, 0x000000ff)) << @as(c_int, 24));
}
pub inline fn __bswap_constant_64(x: anytype) @TypeOf(((((((((x & @as(c_ulonglong, 0xff00000000000000)) >> @as(c_int, 56)) | ((x & @as(c_ulonglong, 0x00ff000000000000)) >> @as(c_int, 40))) | ((x & @as(c_ulonglong, 0x0000ff0000000000)) >> @as(c_int, 24))) | ((x & @as(c_ulonglong, 0x000000ff00000000)) >> @as(c_int, 8))) | ((x & @as(c_ulonglong, 0x00000000ff000000)) << @as(c_int, 8))) | ((x & @as(c_ulonglong, 0x0000000000ff0000)) << @as(c_int, 24))) | ((x & @as(c_ulonglong, 0x000000000000ff00)) << @as(c_int, 40))) | ((x & @as(c_ulonglong, 0x00000000000000ff)) << @as(c_int, 56))) {
    _ = &x;
    return ((((((((x & @as(c_ulonglong, 0xff00000000000000)) >> @as(c_int, 56)) | ((x & @as(c_ulonglong, 0x00ff000000000000)) >> @as(c_int, 40))) | ((x & @as(c_ulonglong, 0x0000ff0000000000)) >> @as(c_int, 24))) | ((x & @as(c_ulonglong, 0x000000ff00000000)) >> @as(c_int, 8))) | ((x & @as(c_ulonglong, 0x00000000ff000000)) << @as(c_int, 8))) | ((x & @as(c_ulonglong, 0x0000000000ff0000)) << @as(c_int, 24))) | ((x & @as(c_ulonglong, 0x000000000000ff00)) << @as(c_int, 40))) | ((x & @as(c_ulonglong, 0x00000000000000ff)) << @as(c_int, 56));
}
pub const _BITS_UINTN_IDENTITY_H = @as(c_int, 1);
pub inline fn htobe16(x: anytype) @TypeOf(__bswap_16(x)) {
    _ = &x;
    return __bswap_16(x);
}
pub inline fn htole16(x: anytype) @TypeOf(__uint16_identity(x)) {
    _ = &x;
    return __uint16_identity(x);
}
pub inline fn be16toh(x: anytype) @TypeOf(__bswap_16(x)) {
    _ = &x;
    return __bswap_16(x);
}
pub inline fn le16toh(x: anytype) @TypeOf(__uint16_identity(x)) {
    _ = &x;
    return __uint16_identity(x);
}
pub inline fn htobe32(x: anytype) @TypeOf(__bswap_32(x)) {
    _ = &x;
    return __bswap_32(x);
}
pub inline fn htole32(x: anytype) @TypeOf(__uint32_identity(x)) {
    _ = &x;
    return __uint32_identity(x);
}
pub inline fn be32toh(x: anytype) @TypeOf(__bswap_32(x)) {
    _ = &x;
    return __bswap_32(x);
}
pub inline fn le32toh(x: anytype) @TypeOf(__uint32_identity(x)) {
    _ = &x;
    return __uint32_identity(x);
}
pub inline fn htobe64(x: anytype) @TypeOf(__bswap_64(x)) {
    _ = &x;
    return __bswap_64(x);
}
pub inline fn htole64(x: anytype) @TypeOf(__uint64_identity(x)) {
    _ = &x;
    return __uint64_identity(x);
}
pub inline fn be64toh(x: anytype) @TypeOf(__bswap_64(x)) {
    _ = &x;
    return __bswap_64(x);
}
pub inline fn le64toh(x: anytype) @TypeOf(__uint64_identity(x)) {
    _ = &x;
    return __uint64_identity(x);
}
pub const _SYS_SELECT_H = @as(c_int, 1);
pub const __FD_ZERO = @compileError("unable to translate macro: undefined identifier `__i`"); // /usr/include/bits/select.h:25:9
pub const __FD_SET = @compileError("unable to translate C expr: expected ')' instead got '|='"); // /usr/include/bits/select.h:32:9
pub const __FD_CLR = @compileError("unable to translate C expr: expected ')' instead got '&='"); // /usr/include/bits/select.h:34:9
pub inline fn __FD_ISSET(d: anytype, s: anytype) @TypeOf((__FDS_BITS(s)[@as(usize, @intCast(__FD_ELT(d)))] & __FD_MASK(d)) != @as(c_int, 0)) {
    _ = &d;
    _ = &s;
    return (__FDS_BITS(s)[@as(usize, @intCast(__FD_ELT(d)))] & __FD_MASK(d)) != @as(c_int, 0);
}
pub const __sigset_t_defined = @as(c_int, 1);
pub const ____sigset_t_defined = "";
pub const _SIGSET_NWORDS = __helpers.div(@as(c_int, 1024), @as(c_int, 8) * __helpers.sizeof(c_ulong));
pub const __timeval_defined = @as(c_int, 1);
pub const _STRUCT_TIMESPEC = @as(c_int, 1);
pub const __suseconds_t_defined = "";
pub const __NFDBITS = @as(c_int, 8) * __helpers.cast(c_int, __helpers.sizeof(__fd_mask));
pub inline fn __FD_ELT(d: anytype) @TypeOf(__helpers.div(d, __NFDBITS)) {
    _ = &d;
    return __helpers.div(d, __NFDBITS);
}
pub inline fn __FD_MASK(d: anytype) __fd_mask {
    _ = &d;
    return __helpers.cast(__fd_mask, @as(c_ulong, 1) << __helpers.rem(d, __NFDBITS));
}
pub inline fn __FDS_BITS(set: anytype) @TypeOf(set.*.__fds_bits) {
    _ = &set;
    return set.*.__fds_bits;
}
pub const FD_SETSIZE = __FD_SETSIZE;
pub const NFDBITS = __NFDBITS;
pub inline fn FD_SET(fd: anytype, fdsetp: anytype) @TypeOf(__FD_SET(fd, fdsetp)) {
    _ = &fd;
    _ = &fdsetp;
    return __FD_SET(fd, fdsetp);
}
pub inline fn FD_CLR(fd: anytype, fdsetp: anytype) @TypeOf(__FD_CLR(fd, fdsetp)) {
    _ = &fd;
    _ = &fdsetp;
    return __FD_CLR(fd, fdsetp);
}
pub inline fn FD_ISSET(fd: anytype, fdsetp: anytype) @TypeOf(__FD_ISSET(fd, fdsetp)) {
    _ = &fd;
    _ = &fdsetp;
    return __FD_ISSET(fd, fdsetp);
}
pub inline fn FD_ZERO(fdsetp: anytype) @TypeOf(__FD_ZERO(fdsetp)) {
    _ = &fdsetp;
    return __FD_ZERO(fdsetp);
}
pub const __blksize_t_defined = "";
pub const __blkcnt_t_defined = "";
pub const __fsblkcnt_t_defined = "";
pub const __fsfilcnt_t_defined = "";
pub const _BITS_PTHREADTYPES_COMMON_H = @as(c_int, 1);
pub const _THREAD_SHARED_TYPES_H = @as(c_int, 1);
pub const _BITS_PTHREADTYPES_ARCH_H = @as(c_int, 1);
pub const __SIZEOF_PTHREAD_MUTEX_T = @as(c_int, 40);
pub const __SIZEOF_PTHREAD_ATTR_T = @as(c_int, 56);
pub const __SIZEOF_PTHREAD_RWLOCK_T = @as(c_int, 56);
pub const __SIZEOF_PTHREAD_BARRIER_T = @as(c_int, 32);
pub const __SIZEOF_PTHREAD_MUTEXATTR_T = @as(c_int, 4);
pub const __SIZEOF_PTHREAD_COND_T = @as(c_int, 48);
pub const __SIZEOF_PTHREAD_CONDATTR_T = @as(c_int, 4);
pub const __SIZEOF_PTHREAD_RWLOCKATTR_T = @as(c_int, 8);
pub const __SIZEOF_PTHREAD_BARRIERATTR_T = @as(c_int, 4);
pub const __LOCK_ALIGNMENT = "";
pub const __ONCE_ALIGNMENT = "";
pub const _BITS_ATOMIC_WIDE_COUNTER_H = "";
pub const _THREAD_MUTEX_INTERNAL_H = @as(c_int, 1);
pub const __PTHREAD_MUTEX_HAVE_PREV = @as(c_int, 1);
pub const __PTHREAD_MUTEX_INITIALIZER = @compileError("unable to translate C expr: unexpected token '{'"); // /usr/include/bits/struct_mutex.h:55:10
pub const _RWLOCK_INTERNAL_H = "";
pub inline fn __PTHREAD_RWLOCK_INITIALIZER(__flags: anytype) @TypeOf(__flags) {
    _ = &__flags;
    return blk: {
        _ = @as(c_int, 0);
        _ = @as(c_int, 0);
        _ = @as(c_int, 0);
        _ = @as(c_int, 0);
        _ = @as(c_int, 0);
        _ = @as(c_int, 0);
        _ = @as(c_int, 0);
        _ = @as(c_int, 0);
        _ = @as(c_int, 0);
        _ = @as(c_int, 0);
        break :blk __flags;
    };
}
pub const __ONCE_FLAG_INIT = @compileError("unable to translate C expr: unexpected token '{'"); // /usr/include/bits/thread-shared-types.h:114:9
pub const __have_pthread_attr_t = @as(c_int, 1);
pub const __STDC_VERSION_STDARG_H__ = @as(c_int, 0);
pub const va_start = @compileError("unable to translate macro: undefined identifier `__builtin_va_start`"); // /usr/lib/zig/compiler/aro/include/stdarg.h:12:9
pub const va_end = @compileError("unable to translate macro: undefined identifier `__builtin_va_end`"); // /usr/lib/zig/compiler/aro/include/stdarg.h:14:9
pub const va_arg = @compileError("unable to translate macro: undefined identifier `__builtin_va_arg`"); // /usr/lib/zig/compiler/aro/include/stdarg.h:15:9
pub const __va_copy = @compileError("unable to translate macro: undefined identifier `__builtin_va_copy`"); // /usr/lib/zig/compiler/aro/include/stdarg.h:18:9
pub const va_copy = @compileError("unable to translate macro: undefined identifier `__builtin_va_copy`"); // /usr/lib/zig/compiler/aro/include/stdarg.h:22:9
pub const __GNUC_VA_LIST = @as(c_int, 1);
pub const ARCHIVE_H_INCLUDED = "";
pub const ARCHIVE_VERSION_NUMBER = __helpers.promoteIntLiteral(c_int, 3008008, .decimal);
pub const _SYS_STAT_H = @as(c_int, 1);
pub const _BITS_STAT_H = @as(c_int, 1);
pub const _BITS_STRUCT_STAT_H = @as(c_int, 1);
pub const st_atime = @compileError("unable to translate macro: undefined identifier `st_atim`"); // /usr/include/bits/struct_stat.h:77:11
pub const st_mtime = @compileError("unable to translate macro: undefined identifier `st_mtim`"); // /usr/include/bits/struct_stat.h:78:11
pub const st_ctime = @compileError("unable to translate macro: undefined identifier `st_ctim`"); // /usr/include/bits/struct_stat.h:79:11
pub const _STATBUF_ST_BLKSIZE = "";
pub const _STATBUF_ST_RDEV = "";
pub const _STATBUF_ST_NSEC = "";
pub const __S_IFMT = __helpers.promoteIntLiteral(c_int, 0o170000, .octal);
pub const __S_IFDIR = @as(c_int, 0o040000);
pub const __S_IFCHR = @as(c_int, 0o020000);
pub const __S_IFBLK = @as(c_int, 0o060000);
pub const __S_IFREG = __helpers.promoteIntLiteral(c_int, 0o100000, .octal);
pub const __S_IFIFO = @as(c_int, 0o010000);
pub const __S_IFLNK = __helpers.promoteIntLiteral(c_int, 0o120000, .octal);
pub const __S_IFSOCK = __helpers.promoteIntLiteral(c_int, 0o140000, .octal);
pub inline fn __S_TYPEISMQ(buf: anytype) @TypeOf(buf.*.st_mode - buf.*.st_mode) {
    _ = &buf;
    return buf.*.st_mode - buf.*.st_mode;
}
pub inline fn __S_TYPEISSEM(buf: anytype) @TypeOf(buf.*.st_mode - buf.*.st_mode) {
    _ = &buf;
    return buf.*.st_mode - buf.*.st_mode;
}
pub inline fn __S_TYPEISSHM(buf: anytype) @TypeOf(buf.*.st_mode - buf.*.st_mode) {
    _ = &buf;
    return buf.*.st_mode - buf.*.st_mode;
}
pub const __S_ISUID = @as(c_int, 0o4000);
pub const __S_ISGID = @as(c_int, 0o2000);
pub const __S_ISVTX = @as(c_int, 0o1000);
pub const __S_IREAD = @as(c_int, 0o400);
pub const __S_IWRITE = @as(c_int, 0o200);
pub const __S_IEXEC = @as(c_int, 0o100);
pub const UTIME_NOW = (@as(c_long, 1) << @as(c_int, 30)) - @as(c_long, 1);
pub const UTIME_OMIT = (@as(c_long, 1) << @as(c_int, 30)) - @as(c_long, 2);
pub const S_IFMT = __S_IFMT;
pub const S_IFDIR = __S_IFDIR;
pub const S_IFCHR = __S_IFCHR;
pub const S_IFBLK = __S_IFBLK;
pub const S_IFREG = __S_IFREG;
pub const S_IFIFO = __S_IFIFO;
pub const S_IFLNK = __S_IFLNK;
pub const S_IFSOCK = __S_IFSOCK;
pub inline fn __S_ISTYPE(mode: anytype, mask: anytype) @TypeOf((mode & __S_IFMT) == mask) {
    _ = &mode;
    _ = &mask;
    return (mode & __S_IFMT) == mask;
}
pub inline fn S_ISDIR(mode: anytype) @TypeOf(__S_ISTYPE(mode, __S_IFDIR)) {
    _ = &mode;
    return __S_ISTYPE(mode, __S_IFDIR);
}
pub inline fn S_ISCHR(mode: anytype) @TypeOf(__S_ISTYPE(mode, __S_IFCHR)) {
    _ = &mode;
    return __S_ISTYPE(mode, __S_IFCHR);
}
pub inline fn S_ISBLK(mode: anytype) @TypeOf(__S_ISTYPE(mode, __S_IFBLK)) {
    _ = &mode;
    return __S_ISTYPE(mode, __S_IFBLK);
}
pub inline fn S_ISREG(mode: anytype) @TypeOf(__S_ISTYPE(mode, __S_IFREG)) {
    _ = &mode;
    return __S_ISTYPE(mode, __S_IFREG);
}
pub inline fn S_ISFIFO(mode: anytype) @TypeOf(__S_ISTYPE(mode, __S_IFIFO)) {
    _ = &mode;
    return __S_ISTYPE(mode, __S_IFIFO);
}
pub inline fn S_ISLNK(mode: anytype) @TypeOf(__S_ISTYPE(mode, __S_IFLNK)) {
    _ = &mode;
    return __S_ISTYPE(mode, __S_IFLNK);
}
pub inline fn S_ISSOCK(mode: anytype) @TypeOf(__S_ISTYPE(mode, __S_IFSOCK)) {
    _ = &mode;
    return __S_ISTYPE(mode, __S_IFSOCK);
}
pub inline fn S_TYPEISMQ(buf: anytype) @TypeOf(__S_TYPEISMQ(buf)) {
    _ = &buf;
    return __S_TYPEISMQ(buf);
}
pub inline fn S_TYPEISSEM(buf: anytype) @TypeOf(__S_TYPEISSEM(buf)) {
    _ = &buf;
    return __S_TYPEISSEM(buf);
}
pub inline fn S_TYPEISSHM(buf: anytype) @TypeOf(__S_TYPEISSHM(buf)) {
    _ = &buf;
    return __S_TYPEISSHM(buf);
}
pub const S_ISUID = __S_ISUID;
pub const S_ISGID = __S_ISGID;
pub const S_ISVTX = __S_ISVTX;
pub const S_IRUSR = __S_IREAD;
pub const S_IWUSR = __S_IWRITE;
pub const S_IXUSR = __S_IEXEC;
pub const S_IRWXU = (__S_IREAD | __S_IWRITE) | __S_IEXEC;
pub const S_IREAD = S_IRUSR;
pub const S_IWRITE = S_IWUSR;
pub const S_IEXEC = S_IXUSR;
pub const S_IRGRP = S_IRUSR >> @as(c_int, 3);
pub const S_IWGRP = S_IWUSR >> @as(c_int, 3);
pub const S_IXGRP = S_IXUSR >> @as(c_int, 3);
pub const S_IRWXG = S_IRWXU >> @as(c_int, 3);
pub const S_IROTH = S_IRGRP >> @as(c_int, 3);
pub const S_IWOTH = S_IWGRP >> @as(c_int, 3);
pub const S_IXOTH = S_IXGRP >> @as(c_int, 3);
pub const S_IRWXO = S_IRWXG >> @as(c_int, 3);
pub const ACCESSPERMS = (S_IRWXU | S_IRWXG) | S_IRWXO;
pub const ALLPERMS = ((((S_ISUID | S_ISGID) | S_ISVTX) | S_IRWXU) | S_IRWXG) | S_IRWXO;
pub const DEFFILEMODE = ((((S_IRUSR | S_IWUSR) | S_IRGRP) | S_IWGRP) | S_IROTH) | S_IWOTH;
pub const S_BLKSIZE = @as(c_int, 512);
pub const _STDIO_H = @as(c_int, 1);
pub const __need_NULL = "";
pub const __need___va_list = "";
pub const _____fpos_t_defined = @as(c_int, 1);
pub const ____mbstate_t_defined = @as(c_int, 1);
pub const _____fpos64_t_defined = @as(c_int, 1);
pub const ____FILE_defined = @as(c_int, 1);
pub const __FILE_defined = @as(c_int, 1);
pub const __struct_FILE_defined = @as(c_int, 1);
pub const __getc_unlocked_body = @compileError("TODO postfix inc/dec expr"); // /usr/include/bits/types/struct_FILE.h:113:9
pub const __putc_unlocked_body = @compileError("TODO postfix inc/dec expr"); // /usr/include/bits/types/struct_FILE.h:117:9
pub const _IO_EOF_SEEN = @as(c_int, 0x0010);
pub inline fn __feof_unlocked_body(_fp: anytype) @TypeOf((_fp.*._flags & _IO_EOF_SEEN) != @as(c_int, 0)) {
    _ = &_fp;
    return (_fp.*._flags & _IO_EOF_SEEN) != @as(c_int, 0);
}
pub const _IO_ERR_SEEN = @as(c_int, 0x0020);
pub inline fn __ferror_unlocked_body(_fp: anytype) @TypeOf((_fp.*._flags & _IO_ERR_SEEN) != @as(c_int, 0)) {
    _ = &_fp;
    return (_fp.*._flags & _IO_ERR_SEEN) != @as(c_int, 0);
}
pub const _IO_USER_LOCK = __helpers.promoteIntLiteral(c_int, 0x8000, .hex);
pub const __cookie_io_functions_t_defined = @as(c_int, 1);
pub const _VA_LIST_DEFINED = "";
pub const _IOFBF = @as(c_int, 0);
pub const _IOLBF = @as(c_int, 1);
pub const _IONBF = @as(c_int, 2);
pub const BUFSIZ = @as(c_int, 8192);
pub const EOF = -@as(c_int, 1);
pub const SEEK_SET = @as(c_int, 0);
pub const SEEK_CUR = @as(c_int, 1);
pub const SEEK_END = @as(c_int, 2);
pub const P_tmpdir = "/tmp";
pub const L_tmpnam = @as(c_int, 20);
pub const TMP_MAX = __helpers.promoteIntLiteral(c_int, 238328, .decimal);
pub const _BITS_STDIO_LIM_H = @as(c_int, 1);
pub const FILENAME_MAX = @as(c_int, 4096);
pub const L_ctermid = @as(c_int, 9);
pub const FOPEN_MAX = @as(c_int, 16);
pub const __attr_dealloc_fclose = __attr_dealloc(fclose, @as(c_int, 1));
pub const _BITS_FLOATN_H = "";
pub const __HAVE_FLOAT128 = @as(c_int, 1);
pub const __HAVE_DISTINCT_FLOAT128 = @as(c_int, 1);
pub const __HAVE_FLOAT64X = @as(c_int, 1);
pub const __HAVE_FLOAT64X_LONG_DOUBLE = @as(c_int, 1);
pub const __f128 = @compileError("unable to translate macro: undefined identifier `f128`"); // /usr/include/bits/floatn.h:72:12
pub const __CFLOAT128 = @compileError("unable to translate: invalid numeric type"); // /usr/include/bits/floatn.h:86:12
pub const _BITS_FLOATN_COMMON_H = "";
pub const __HAVE_FLOAT16 = @as(c_int, 0);
pub const __HAVE_FLOAT32 = @as(c_int, 1);
pub const __HAVE_FLOAT64 = @as(c_int, 1);
pub const __HAVE_FLOAT32X = @as(c_int, 1);
pub const __HAVE_FLOAT128X = @as(c_int, 0);
pub const __HAVE_DISTINCT_FLOAT16 = __HAVE_FLOAT16;
pub const __HAVE_DISTINCT_FLOAT32 = @as(c_int, 0);
pub const __HAVE_DISTINCT_FLOAT64 = @as(c_int, 0);
pub const __HAVE_DISTINCT_FLOAT32X = @as(c_int, 0);
pub const __HAVE_DISTINCT_FLOAT64X = @as(c_int, 0);
pub const __HAVE_DISTINCT_FLOAT128X = __HAVE_FLOAT128X;
pub const __HAVE_FLOAT128_UNLIKE_LDBL = (__HAVE_DISTINCT_FLOAT128 != 0) and (__LDBL_MANT_DIG__ != @as(c_int, 113));
pub const __HAVE_FLOATN_NOT_TYPEDEF = @as(c_int, 1);
pub const __f32 = @compileError("unable to translate macro: undefined identifier `f32`"); // /usr/include/bits/floatn-common.h:93:12
pub const __f64 = @compileError("unable to translate macro: undefined identifier `f64`"); // /usr/include/bits/floatn-common.h:105:12
pub const __f32x = @compileError("unable to translate macro: undefined identifier `f32x`"); // /usr/include/bits/floatn-common.h:113:12
pub const __f64x = @compileError("unable to translate macro: undefined identifier `f64x`"); // /usr/include/bits/floatn-common.h:125:12
pub const __CFLOAT32 = @compileError("unable to translate: invalid numeric type"); // /usr/include/bits/floatn-common.h:151:12
pub const __CFLOAT64 = @compileError("unable to translate: invalid numeric type"); // /usr/include/bits/floatn-common.h:163:12
pub const __CFLOAT32X = @compileError("unable to translate: invalid numeric type"); // /usr/include/bits/floatn-common.h:171:12
pub const __CFLOAT64X = @compileError("unable to translate: invalid numeric type"); // /usr/include/bits/floatn-common.h:183:12
pub const _TIME_H = @as(c_int, 1);
pub const _BITS_TIME_H = @as(c_int, 1);
pub const CLOCKS_PER_SEC = __helpers.cast(__clock_t, __helpers.promoteIntLiteral(c_int, 1000000, .decimal));
pub const CLOCK_REALTIME = @as(c_int, 0);
pub const CLOCK_MONOTONIC = @as(c_int, 1);
pub const CLOCK_PROCESS_CPUTIME_ID = @as(c_int, 2);
pub const CLOCK_THREAD_CPUTIME_ID = @as(c_int, 3);
pub const CLOCK_MONOTONIC_RAW = @as(c_int, 4);
pub const CLOCK_REALTIME_COARSE = @as(c_int, 5);
pub const CLOCK_MONOTONIC_COARSE = @as(c_int, 6);
pub const CLOCK_BOOTTIME = @as(c_int, 7);
pub const CLOCK_REALTIME_ALARM = @as(c_int, 8);
pub const CLOCK_BOOTTIME_ALARM = @as(c_int, 9);
pub const CLOCK_TAI = @as(c_int, 11);
pub const TIMER_ABSTIME = @as(c_int, 1);
pub const __struct_tm_defined = @as(c_int, 1);
pub const __itimerspec_defined = @as(c_int, 1);
pub const _BITS_TYPES_LOCALE_T_H = @as(c_int, 1);
pub const _BITS_TYPES___LOCALE_T_H = @as(c_int, 1);
pub const TIME_UTC = @as(c_int, 1);
pub inline fn __isleap(year: anytype) @TypeOf((__helpers.rem(year, @as(c_int, 4)) == @as(c_int, 0)) and ((__helpers.rem(year, @as(c_int, 100)) != @as(c_int, 0)) or (__helpers.rem(year, @as(c_int, 400)) == @as(c_int, 0)))) {
    _ = &year;
    return (__helpers.rem(year, @as(c_int, 4)) == @as(c_int, 0)) and ((__helpers.rem(year, @as(c_int, 100)) != @as(c_int, 0)) or (__helpers.rem(year, @as(c_int, 400)) == @as(c_int, 0)));
}
pub const __CLANG_INTTYPES_H = "";
pub const _INTTYPES_H = @as(c_int, 1);
pub const ____gwchar_t_defined = @as(c_int, 1);
pub const __PRI64_PREFIX = "l";
pub const __PRIPTR_PREFIX = "l";
pub const PRId8 = "hhd";
pub const PRId16 = "hd";
pub const PRId32 = "d";
pub const PRId64 = __PRI64_PREFIX ++ "d";
pub const PRIdLEAST8 = "hhd";
pub const PRIdLEAST16 = "hd";
pub const PRIdLEAST32 = "d";
pub const PRIdLEAST64 = __PRI64_PREFIX ++ "d";
pub const PRIdFAST8 = "hhd";
pub const PRIdFAST16 = __PRIPTR_PREFIX ++ "d";
pub const PRIdFAST32 = __PRIPTR_PREFIX ++ "d";
pub const PRIdFAST64 = __PRI64_PREFIX ++ "d";
pub const PRIi8 = "hhi";
pub const PRIi16 = "hi";
pub const PRIi32 = "i";
pub const PRIi64 = __PRI64_PREFIX ++ "i";
pub const PRIiLEAST8 = "hhi";
pub const PRIiLEAST16 = "hi";
pub const PRIiLEAST32 = "i";
pub const PRIiLEAST64 = __PRI64_PREFIX ++ "i";
pub const PRIiFAST8 = "hhi";
pub const PRIiFAST16 = __PRIPTR_PREFIX ++ "i";
pub const PRIiFAST32 = __PRIPTR_PREFIX ++ "i";
pub const PRIiFAST64 = __PRI64_PREFIX ++ "i";
pub const PRIo8 = "hho";
pub const PRIo16 = "ho";
pub const PRIo32 = "o";
pub const PRIo64 = __PRI64_PREFIX ++ "o";
pub const PRIoLEAST8 = "hho";
pub const PRIoLEAST16 = "ho";
pub const PRIoLEAST32 = "o";
pub const PRIoLEAST64 = __PRI64_PREFIX ++ "o";
pub const PRIoFAST8 = "hho";
pub const PRIoFAST16 = __PRIPTR_PREFIX ++ "o";
pub const PRIoFAST32 = __PRIPTR_PREFIX ++ "o";
pub const PRIoFAST64 = __PRI64_PREFIX ++ "o";
pub const PRIu8 = "hhu";
pub const PRIu16 = "hu";
pub const PRIu32 = "u";
pub const PRIu64 = __PRI64_PREFIX ++ "u";
pub const PRIuLEAST8 = "hhu";
pub const PRIuLEAST16 = "hu";
pub const PRIuLEAST32 = "u";
pub const PRIuLEAST64 = __PRI64_PREFIX ++ "u";
pub const PRIuFAST8 = "hhu";
pub const PRIuFAST16 = __PRIPTR_PREFIX ++ "u";
pub const PRIuFAST32 = __PRIPTR_PREFIX ++ "u";
pub const PRIuFAST64 = __PRI64_PREFIX ++ "u";
pub const PRIx8 = "hhx";
pub const PRIx16 = "hx";
pub const PRIx32 = "x";
pub const PRIx64 = __PRI64_PREFIX ++ "x";
pub const PRIxLEAST8 = "hhx";
pub const PRIxLEAST16 = "hx";
pub const PRIxLEAST32 = "x";
pub const PRIxLEAST64 = __PRI64_PREFIX ++ "x";
pub const PRIxFAST8 = "hhx";
pub const PRIxFAST16 = __PRIPTR_PREFIX ++ "x";
pub const PRIxFAST32 = __PRIPTR_PREFIX ++ "x";
pub const PRIxFAST64 = __PRI64_PREFIX ++ "x";
pub const PRIX8 = "hhX";
pub const PRIX16 = "hX";
pub const PRIX32 = "X";
pub const PRIX64 = __PRI64_PREFIX ++ "X";
pub const PRIXLEAST8 = "hhX";
pub const PRIXLEAST16 = "hX";
pub const PRIXLEAST32 = "X";
pub const PRIXLEAST64 = __PRI64_PREFIX ++ "X";
pub const PRIXFAST8 = "hhX";
pub const PRIXFAST16 = __PRIPTR_PREFIX ++ "X";
pub const PRIXFAST32 = __PRIPTR_PREFIX ++ "X";
pub const PRIXFAST64 = __PRI64_PREFIX ++ "X";
pub const PRIdMAX = __PRI64_PREFIX ++ "d";
pub const PRIiMAX = __PRI64_PREFIX ++ "i";
pub const PRIoMAX = __PRI64_PREFIX ++ "o";
pub const PRIuMAX = __PRI64_PREFIX ++ "u";
pub const PRIxMAX = __PRI64_PREFIX ++ "x";
pub const PRIXMAX = __PRI64_PREFIX ++ "X";
pub const PRIdPTR = __PRIPTR_PREFIX ++ "d";
pub const PRIiPTR = __PRIPTR_PREFIX ++ "i";
pub const PRIoPTR = __PRIPTR_PREFIX ++ "o";
pub const PRIuPTR = __PRIPTR_PREFIX ++ "u";
pub const PRIxPTR = __PRIPTR_PREFIX ++ "x";
pub const PRIXPTR = __PRIPTR_PREFIX ++ "X";
pub const SCNd8 = "hhd";
pub const SCNd16 = "hd";
pub const SCNd32 = "d";
pub const SCNd64 = __PRI64_PREFIX ++ "d";
pub const SCNdLEAST8 = "hhd";
pub const SCNdLEAST16 = "hd";
pub const SCNdLEAST32 = "d";
pub const SCNdLEAST64 = __PRI64_PREFIX ++ "d";
pub const SCNdFAST8 = "hhd";
pub const SCNdFAST16 = __PRIPTR_PREFIX ++ "d";
pub const SCNdFAST32 = __PRIPTR_PREFIX ++ "d";
pub const SCNdFAST64 = __PRI64_PREFIX ++ "d";
pub const SCNi8 = "hhi";
pub const SCNi16 = "hi";
pub const SCNi32 = "i";
pub const SCNi64 = __PRI64_PREFIX ++ "i";
pub const SCNiLEAST8 = "hhi";
pub const SCNiLEAST16 = "hi";
pub const SCNiLEAST32 = "i";
pub const SCNiLEAST64 = __PRI64_PREFIX ++ "i";
pub const SCNiFAST8 = "hhi";
pub const SCNiFAST16 = __PRIPTR_PREFIX ++ "i";
pub const SCNiFAST32 = __PRIPTR_PREFIX ++ "i";
pub const SCNiFAST64 = __PRI64_PREFIX ++ "i";
pub const SCNu8 = "hhu";
pub const SCNu16 = "hu";
pub const SCNu32 = "u";
pub const SCNu64 = __PRI64_PREFIX ++ "u";
pub const SCNuLEAST8 = "hhu";
pub const SCNuLEAST16 = "hu";
pub const SCNuLEAST32 = "u";
pub const SCNuLEAST64 = __PRI64_PREFIX ++ "u";
pub const SCNuFAST8 = "hhu";
pub const SCNuFAST16 = __PRIPTR_PREFIX ++ "u";
pub const SCNuFAST32 = __PRIPTR_PREFIX ++ "u";
pub const SCNuFAST64 = __PRI64_PREFIX ++ "u";
pub const SCNo8 = "hho";
pub const SCNo16 = "ho";
pub const SCNo32 = "o";
pub const SCNo64 = __PRI64_PREFIX ++ "o";
pub const SCNoLEAST8 = "hho";
pub const SCNoLEAST16 = "ho";
pub const SCNoLEAST32 = "o";
pub const SCNoLEAST64 = __PRI64_PREFIX ++ "o";
pub const SCNoFAST8 = "hho";
pub const SCNoFAST16 = __PRIPTR_PREFIX ++ "o";
pub const SCNoFAST32 = __PRIPTR_PREFIX ++ "o";
pub const SCNoFAST64 = __PRI64_PREFIX ++ "o";
pub const SCNx8 = "hhx";
pub const SCNx16 = "hx";
pub const SCNx32 = "x";
pub const SCNx64 = __PRI64_PREFIX ++ "x";
pub const SCNxLEAST8 = "hhx";
pub const SCNxLEAST16 = "hx";
pub const SCNxLEAST32 = "x";
pub const SCNxLEAST64 = __PRI64_PREFIX ++ "x";
pub const SCNxFAST8 = "hhx";
pub const SCNxFAST16 = __PRIPTR_PREFIX ++ "x";
pub const SCNxFAST32 = __PRIPTR_PREFIX ++ "x";
pub const SCNxFAST64 = __PRI64_PREFIX ++ "x";
pub const SCNdMAX = __PRI64_PREFIX ++ "d";
pub const SCNiMAX = __PRI64_PREFIX ++ "i";
pub const SCNoMAX = __PRI64_PREFIX ++ "o";
pub const SCNuMAX = __PRI64_PREFIX ++ "u";
pub const SCNxMAX = __PRI64_PREFIX ++ "x";
pub const SCNdPTR = __PRIPTR_PREFIX ++ "d";
pub const SCNiPTR = __PRIPTR_PREFIX ++ "i";
pub const SCNoPTR = __PRIPTR_PREFIX ++ "o";
pub const SCNuPTR = __PRIPTR_PREFIX ++ "u";
pub const SCNxPTR = __PRIPTR_PREFIX ++ "x";
pub const __LA_INT64_T = la_int64_t;
pub const __LA_INT64_T_DEFINED = "";
pub const _UNISTD_H = @as(c_int, 1);
pub const _POSIX_VERSION = @as(c_long, 200809);
pub const __POSIX2_THIS_VERSION = @as(c_long, 200809);
pub const _POSIX2_VERSION = __POSIX2_THIS_VERSION;
pub const _POSIX2_C_VERSION = __POSIX2_THIS_VERSION;
pub const _POSIX2_C_BIND = __POSIX2_THIS_VERSION;
pub const _POSIX2_C_DEV = __POSIX2_THIS_VERSION;
pub const _POSIX2_SW_DEV = __POSIX2_THIS_VERSION;
pub const _POSIX2_LOCALEDEF = __POSIX2_THIS_VERSION;
pub const _XOPEN_VERSION = @as(c_int, 700);
pub const _XOPEN_XCU_VERSION = @as(c_int, 4);
pub const _XOPEN_XPG2 = @as(c_int, 1);
pub const _XOPEN_XPG3 = @as(c_int, 1);
pub const _XOPEN_XPG4 = @as(c_int, 1);
pub const _XOPEN_UNIX = @as(c_int, 1);
pub const _XOPEN_ENH_I18N = @as(c_int, 1);
pub const _XOPEN_LEGACY = @as(c_int, 1);
pub const _BITS_POSIX_OPT_H = @as(c_int, 1);
pub const _POSIX_JOB_CONTROL = @as(c_int, 1);
pub const _POSIX_SAVED_IDS = @as(c_int, 1);
pub const _POSIX_PRIORITY_SCHEDULING = @as(c_long, 200809);
pub const _POSIX_SYNCHRONIZED_IO = @as(c_long, 200809);
pub const _POSIX_FSYNC = @as(c_long, 200809);
pub const _POSIX_MAPPED_FILES = @as(c_long, 200809);
pub const _POSIX_MEMLOCK = @as(c_long, 200809);
pub const _POSIX_MEMLOCK_RANGE = @as(c_long, 200809);
pub const _POSIX_MEMORY_PROTECTION = @as(c_long, 200809);
pub const _POSIX_CHOWN_RESTRICTED = @as(c_int, 0);
pub const _POSIX_VDISABLE = @as(c_int, 0);
pub const _POSIX_NO_TRUNC = @as(c_int, 1);
pub const _XOPEN_REALTIME = @as(c_int, 1);
pub const _XOPEN_REALTIME_THREADS = @as(c_int, 1);
pub const _XOPEN_SHM = @as(c_int, 1);
pub const _POSIX_THREADS = @as(c_long, 200809);
pub const _POSIX_REENTRANT_FUNCTIONS = @as(c_int, 1);
pub const _POSIX_THREAD_SAFE_FUNCTIONS = @as(c_long, 200809);
pub const _POSIX_THREAD_PRIORITY_SCHEDULING = @as(c_long, 200809);
pub const _POSIX_THREAD_ATTR_STACKSIZE = @as(c_long, 200809);
pub const _POSIX_THREAD_ATTR_STACKADDR = @as(c_long, 200809);
pub const _POSIX_THREAD_PRIO_INHERIT = @as(c_long, 200809);
pub const _POSIX_THREAD_PRIO_PROTECT = @as(c_long, 200809);
pub const _POSIX_THREAD_ROBUST_PRIO_INHERIT = @as(c_long, 200809);
pub const _POSIX_THREAD_ROBUST_PRIO_PROTECT = -@as(c_int, 1);
pub const _POSIX_SEMAPHORES = @as(c_long, 200809);
pub const _POSIX_REALTIME_SIGNALS = @as(c_long, 200809);
pub const _POSIX_ASYNCHRONOUS_IO = @as(c_long, 200809);
pub const _POSIX_ASYNC_IO = @as(c_int, 1);
pub const _LFS_ASYNCHRONOUS_IO = @as(c_int, 1);
pub const _POSIX_PRIORITIZED_IO = @as(c_long, 200809);
pub const _LFS64_ASYNCHRONOUS_IO = @as(c_int, 1);
pub const _LFS_LARGEFILE = @as(c_int, 1);
pub const _LFS64_LARGEFILE = @as(c_int, 1);
pub const _LFS64_STDIO = @as(c_int, 1);
pub const _POSIX_SHARED_MEMORY_OBJECTS = @as(c_long, 200809);
pub const _POSIX_CPUTIME = @as(c_int, 0);
pub const _POSIX_THREAD_CPUTIME = @as(c_int, 0);
pub const _POSIX_REGEXP = @as(c_int, 1);
pub const _POSIX_READER_WRITER_LOCKS = @as(c_long, 200809);
pub const _POSIX_SHELL = @as(c_int, 1);
pub const _POSIX_TIMEOUTS = @as(c_long, 200809);
pub const _POSIX_SPIN_LOCKS = @as(c_long, 200809);
pub const _POSIX_SPAWN = @as(c_long, 200809);
pub const _POSIX_TIMERS = @as(c_long, 200809);
pub const _POSIX_BARRIERS = @as(c_long, 200809);
pub const _POSIX_MESSAGE_PASSING = @as(c_long, 200809);
pub const _POSIX_THREAD_PROCESS_SHARED = @as(c_long, 200809);
pub const _POSIX_MONOTONIC_CLOCK = @as(c_int, 0);
pub const _POSIX_CLOCK_SELECTION = @as(c_long, 200809);
pub const _POSIX_ADVISORY_INFO = @as(c_long, 200809);
pub const _POSIX_IPV6 = @as(c_long, 200809);
pub const _POSIX_RAW_SOCKETS = @as(c_long, 200809);
pub const _POSIX2_CHAR_TERM = @as(c_long, 200809);
pub const _POSIX_SPORADIC_SERVER = -@as(c_int, 1);
pub const _POSIX_THREAD_SPORADIC_SERVER = -@as(c_int, 1);
pub const _POSIX_TRACE = -@as(c_int, 1);
pub const _POSIX_TRACE_EVENT_FILTER = -@as(c_int, 1);
pub const _POSIX_TRACE_INHERIT = -@as(c_int, 1);
pub const _POSIX_TRACE_LOG = -@as(c_int, 1);
pub const _POSIX_TYPED_MEMORY_OBJECTS = -@as(c_int, 1);
pub const _POSIX_V7_LPBIG_OFFBIG = -@as(c_int, 1);
pub const _POSIX_V6_LPBIG_OFFBIG = -@as(c_int, 1);
pub const _XBS5_LPBIG_OFFBIG = -@as(c_int, 1);
pub const _POSIX_V7_LP64_OFF64 = @as(c_int, 1);
pub const _POSIX_V6_LP64_OFF64 = @as(c_int, 1);
pub const _XBS5_LP64_OFF64 = @as(c_int, 1);
pub const __ILP32_OFF32_CFLAGS = "-m32";
pub const __ILP32_OFF32_LDFLAGS = "-m32";
pub const __ILP32_OFFBIG_CFLAGS = "-m32 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64";
pub const __ILP32_OFFBIG_LDFLAGS = "-m32";
pub const __LP64_OFF64_CFLAGS = "-m64";
pub const __LP64_OFF64_LDFLAGS = "-m64";
pub const STDIN_FILENO = @as(c_int, 0);
pub const STDOUT_FILENO = @as(c_int, 1);
pub const STDERR_FILENO = @as(c_int, 2);
pub const __useconds_t_defined = "";
pub const __socklen_t_defined = "";
pub const R_OK = @as(c_int, 4);
pub const W_OK = @as(c_int, 2);
pub const X_OK = @as(c_int, 1);
pub const F_OK = @as(c_int, 0);
pub const L_SET = SEEK_SET;
pub const L_INCR = SEEK_CUR;
pub const L_XTND = SEEK_END;
pub const _SC_PAGE_SIZE = _SC_PAGESIZE;
pub const _CS_POSIX_V6_WIDTH_RESTRICTED_ENVS = _CS_V6_WIDTH_RESTRICTED_ENVS;
pub const _CS_POSIX_V5_WIDTH_RESTRICTED_ENVS = _CS_V5_WIDTH_RESTRICTED_ENVS;
pub const _CS_POSIX_V7_WIDTH_RESTRICTED_ENVS = _CS_V7_WIDTH_RESTRICTED_ENVS;
pub const _GETOPT_POSIX_H = @as(c_int, 1);
pub const _GETOPT_CORE_H = @as(c_int, 1);
pub const F_ULOCK = @as(c_int, 0);
pub const F_LOCK = @as(c_int, 1);
pub const F_TLOCK = @as(c_int, 2);
pub const F_TEST = @as(c_int, 3);
pub const __LA_SSIZE_T = la_ssize_t;
pub const __LA_SSIZE_T_DEFINED = "";
pub const __LA_TIME_T = time_t;
pub const __LA_DEV_T = dev_t;
pub const __LA_PRINTF = @compileError("unable to translate macro: undefined identifier `__format__`"); // /usr/include/archive.h:151:9
pub const __LA_DEPRECATED = @compileError("unable to translate macro: undefined identifier `deprecated`"); // /usr/include/archive_entry.h:162:10
pub const ARCHIVE_VERSION_ONLY_STRING = "3.8.8";
pub const ARCHIVE_VERSION_STRING = "libarchive " ++ ARCHIVE_VERSION_ONLY_STRING;
pub const ARCHIVE_EOF = @as(c_int, 1);
pub const ARCHIVE_OK = @as(c_int, 0);
pub const ARCHIVE_RETRY = -@as(c_int, 10);
pub const ARCHIVE_WARN = -@as(c_int, 20);
pub const ARCHIVE_FAILED = -@as(c_int, 25);
pub const ARCHIVE_FATAL = -@as(c_int, 30);
pub const ARCHIVE_FILTER_NONE = @as(c_int, 0);
pub const ARCHIVE_FILTER_GZIP = @as(c_int, 1);
pub const ARCHIVE_FILTER_BZIP2 = @as(c_int, 2);
pub const ARCHIVE_FILTER_COMPRESS = @as(c_int, 3);
pub const ARCHIVE_FILTER_PROGRAM = @as(c_int, 4);
pub const ARCHIVE_FILTER_LZMA = @as(c_int, 5);
pub const ARCHIVE_FILTER_XZ = @as(c_int, 6);
pub const ARCHIVE_FILTER_UU = @as(c_int, 7);
pub const ARCHIVE_FILTER_RPM = @as(c_int, 8);
pub const ARCHIVE_FILTER_LZIP = @as(c_int, 9);
pub const ARCHIVE_FILTER_LRZIP = @as(c_int, 10);
pub const ARCHIVE_FILTER_LZOP = @as(c_int, 11);
pub const ARCHIVE_FILTER_GRZIP = @as(c_int, 12);
pub const ARCHIVE_FILTER_LZ4 = @as(c_int, 13);
pub const ARCHIVE_FILTER_ZSTD = @as(c_int, 14);
pub const ARCHIVE_COMPRESSION_NONE = ARCHIVE_FILTER_NONE;
pub const ARCHIVE_COMPRESSION_GZIP = ARCHIVE_FILTER_GZIP;
pub const ARCHIVE_COMPRESSION_BZIP2 = ARCHIVE_FILTER_BZIP2;
pub const ARCHIVE_COMPRESSION_COMPRESS = ARCHIVE_FILTER_COMPRESS;
pub const ARCHIVE_COMPRESSION_PROGRAM = ARCHIVE_FILTER_PROGRAM;
pub const ARCHIVE_COMPRESSION_LZMA = ARCHIVE_FILTER_LZMA;
pub const ARCHIVE_COMPRESSION_XZ = ARCHIVE_FILTER_XZ;
pub const ARCHIVE_COMPRESSION_UU = ARCHIVE_FILTER_UU;
pub const ARCHIVE_COMPRESSION_RPM = ARCHIVE_FILTER_RPM;
pub const ARCHIVE_COMPRESSION_LZIP = ARCHIVE_FILTER_LZIP;
pub const ARCHIVE_COMPRESSION_LRZIP = ARCHIVE_FILTER_LRZIP;
pub const ARCHIVE_FORMAT_BASE_MASK = __helpers.promoteIntLiteral(c_int, 0xff0000, .hex);
pub const ARCHIVE_FORMAT_CPIO = __helpers.promoteIntLiteral(c_int, 0x10000, .hex);
pub const ARCHIVE_FORMAT_CPIO_POSIX = ARCHIVE_FORMAT_CPIO | @as(c_int, 1);
pub const ARCHIVE_FORMAT_CPIO_BIN_LE = ARCHIVE_FORMAT_CPIO | @as(c_int, 2);
pub const ARCHIVE_FORMAT_CPIO_BIN_BE = ARCHIVE_FORMAT_CPIO | @as(c_int, 3);
pub const ARCHIVE_FORMAT_CPIO_SVR4_NOCRC = ARCHIVE_FORMAT_CPIO | @as(c_int, 4);
pub const ARCHIVE_FORMAT_CPIO_SVR4_CRC = ARCHIVE_FORMAT_CPIO | @as(c_int, 5);
pub const ARCHIVE_FORMAT_CPIO_AFIO_LARGE = ARCHIVE_FORMAT_CPIO | @as(c_int, 6);
pub const ARCHIVE_FORMAT_CPIO_PWB = ARCHIVE_FORMAT_CPIO | @as(c_int, 7);
pub const ARCHIVE_FORMAT_SHAR = __helpers.promoteIntLiteral(c_int, 0x20000, .hex);
pub const ARCHIVE_FORMAT_SHAR_BASE = ARCHIVE_FORMAT_SHAR | @as(c_int, 1);
pub const ARCHIVE_FORMAT_SHAR_DUMP = ARCHIVE_FORMAT_SHAR | @as(c_int, 2);
pub const ARCHIVE_FORMAT_TAR = __helpers.promoteIntLiteral(c_int, 0x30000, .hex);
pub const ARCHIVE_FORMAT_TAR_USTAR = ARCHIVE_FORMAT_TAR | @as(c_int, 1);
pub const ARCHIVE_FORMAT_TAR_PAX_INTERCHANGE = ARCHIVE_FORMAT_TAR | @as(c_int, 2);
pub const ARCHIVE_FORMAT_TAR_PAX_RESTRICTED = ARCHIVE_FORMAT_TAR | @as(c_int, 3);
pub const ARCHIVE_FORMAT_TAR_GNUTAR = ARCHIVE_FORMAT_TAR | @as(c_int, 4);
pub const ARCHIVE_FORMAT_ISO9660 = __helpers.promoteIntLiteral(c_int, 0x40000, .hex);
pub const ARCHIVE_FORMAT_ISO9660_ROCKRIDGE = ARCHIVE_FORMAT_ISO9660 | @as(c_int, 1);
pub const ARCHIVE_FORMAT_ZIP = __helpers.promoteIntLiteral(c_int, 0x50000, .hex);
pub const ARCHIVE_FORMAT_EMPTY = __helpers.promoteIntLiteral(c_int, 0x60000, .hex);
pub const ARCHIVE_FORMAT_AR = __helpers.promoteIntLiteral(c_int, 0x70000, .hex);
pub const ARCHIVE_FORMAT_AR_GNU = ARCHIVE_FORMAT_AR | @as(c_int, 1);
pub const ARCHIVE_FORMAT_AR_BSD = ARCHIVE_FORMAT_AR | @as(c_int, 2);
pub const ARCHIVE_FORMAT_MTREE = __helpers.promoteIntLiteral(c_int, 0x80000, .hex);
pub const ARCHIVE_FORMAT_RAW = __helpers.promoteIntLiteral(c_int, 0x90000, .hex);
pub const ARCHIVE_FORMAT_XAR = __helpers.promoteIntLiteral(c_int, 0xA0000, .hex);
pub const ARCHIVE_FORMAT_LHA = __helpers.promoteIntLiteral(c_int, 0xB0000, .hex);
pub const ARCHIVE_FORMAT_CAB = __helpers.promoteIntLiteral(c_int, 0xC0000, .hex);
pub const ARCHIVE_FORMAT_RAR = __helpers.promoteIntLiteral(c_int, 0xD0000, .hex);
pub const ARCHIVE_FORMAT_7ZIP = __helpers.promoteIntLiteral(c_int, 0xE0000, .hex);
pub const ARCHIVE_FORMAT_WARC = __helpers.promoteIntLiteral(c_int, 0xF0000, .hex);
pub const ARCHIVE_FORMAT_RAR_V5 = __helpers.promoteIntLiteral(c_int, 0x100000, .hex);
pub const ARCHIVE_READ_FORMAT_CAPS_NONE = @as(c_int, 0);
pub const ARCHIVE_READ_FORMAT_CAPS_ENCRYPT_DATA = @as(c_int, 1) << @as(c_int, 0);
pub const ARCHIVE_READ_FORMAT_CAPS_ENCRYPT_METADATA = @as(c_int, 1) << @as(c_int, 1);
pub const ARCHIVE_READ_FORMAT_ENCRYPTION_UNSUPPORTED = -@as(c_int, 2);
pub const ARCHIVE_READ_FORMAT_ENCRYPTION_DONT_KNOW = -@as(c_int, 1);
pub const ARCHIVE_EXTRACT_OWNER = @as(c_int, 0x0001);
pub const ARCHIVE_EXTRACT_PERM = @as(c_int, 0x0002);
pub const ARCHIVE_EXTRACT_TIME = @as(c_int, 0x0004);
pub const ARCHIVE_EXTRACT_NO_OVERWRITE = @as(c_int, 0x0008);
pub const ARCHIVE_EXTRACT_UNLINK = @as(c_int, 0x0010);
pub const ARCHIVE_EXTRACT_ACL = @as(c_int, 0x0020);
pub const ARCHIVE_EXTRACT_FFLAGS = @as(c_int, 0x0040);
pub const ARCHIVE_EXTRACT_XATTR = @as(c_int, 0x0080);
pub const ARCHIVE_EXTRACT_SECURE_SYMLINKS = @as(c_int, 0x0100);
pub const ARCHIVE_EXTRACT_SECURE_NODOTDOT = @as(c_int, 0x0200);
pub const ARCHIVE_EXTRACT_NO_AUTODIR = @as(c_int, 0x0400);
pub const ARCHIVE_EXTRACT_NO_OVERWRITE_NEWER = @as(c_int, 0x0800);
pub const ARCHIVE_EXTRACT_SPARSE = @as(c_int, 0x1000);
pub const ARCHIVE_EXTRACT_MAC_METADATA = @as(c_int, 0x2000);
pub const ARCHIVE_EXTRACT_NO_HFS_COMPRESSION = @as(c_int, 0x4000);
pub const ARCHIVE_EXTRACT_HFS_COMPRESSION_FORCED = __helpers.promoteIntLiteral(c_int, 0x8000, .hex);
pub const ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS = __helpers.promoteIntLiteral(c_int, 0x10000, .hex);
pub const ARCHIVE_EXTRACT_CLEAR_NOCHANGE_FFLAGS = __helpers.promoteIntLiteral(c_int, 0x20000, .hex);
pub const ARCHIVE_EXTRACT_SAFE_WRITES = __helpers.promoteIntLiteral(c_int, 0x40000, .hex);
pub const ARCHIVE_READDISK_RESTORE_ATIME = @as(c_int, 0x0001);
pub const ARCHIVE_READDISK_HONOR_NODUMP = @as(c_int, 0x0002);
pub const ARCHIVE_READDISK_MAC_COPYFILE = @as(c_int, 0x0004);
pub const ARCHIVE_READDISK_NO_TRAVERSE_MOUNTS = @as(c_int, 0x0008);
pub const ARCHIVE_READDISK_NO_XATTR = @as(c_int, 0x0010);
pub const ARCHIVE_READDISK_NO_ACL = @as(c_int, 0x0020);
pub const ARCHIVE_READDISK_NO_FFLAGS = @as(c_int, 0x0040);
pub const ARCHIVE_READDISK_NO_SPARSE = @as(c_int, 0x0080);
pub const ARCHIVE_MATCH_MTIME = @as(c_int, 0x0100);
pub const ARCHIVE_MATCH_CTIME = @as(c_int, 0x0200);
pub const ARCHIVE_MATCH_NEWER = @as(c_int, 0x0001);
pub const ARCHIVE_MATCH_OLDER = @as(c_int, 0x0002);
pub const ARCHIVE_MATCH_EQUAL = @as(c_int, 0x0010);
pub const ARCHIVE_ENTRY_H_INCLUDED = "";
pub const __LA_MODE_T = mode_t;
pub const __LA_INO_T = la_int64_t;
pub const AE_IFMT = @compileError("unable to translate C expr: expected ')' instead got 'a number'"); // /usr/include/archive_entry.h:215:9
pub const AE_IFREG = @compileError("unable to translate C expr: expected ')' instead got 'a number'"); // /usr/include/archive_entry.h:216:9
pub const AE_IFLNK = @compileError("unable to translate C expr: expected ')' instead got 'a number'"); // /usr/include/archive_entry.h:217:9
pub const AE_IFSOCK = @compileError("unable to translate C expr: expected ')' instead got 'a number'"); // /usr/include/archive_entry.h:218:9
pub const AE_IFCHR = @compileError("unable to translate C expr: expected ')' instead got 'a number'"); // /usr/include/archive_entry.h:219:9
pub const AE_IFBLK = @compileError("unable to translate C expr: expected ')' instead got 'a number'"); // /usr/include/archive_entry.h:220:9
pub const AE_IFDIR = @compileError("unable to translate C expr: expected ')' instead got 'a number'"); // /usr/include/archive_entry.h:221:9
pub const AE_IFIFO = @compileError("unable to translate C expr: expected ')' instead got 'a number'"); // /usr/include/archive_entry.h:222:9
pub const AE_SYMLINK_TYPE_UNDEFINED = @as(c_int, 0);
pub const AE_SYMLINK_TYPE_FILE = @as(c_int, 1);
pub const AE_SYMLINK_TYPE_DIRECTORY = @as(c_int, 2);
pub const ARCHIVE_ENTRY_DIGEST_MD5 = @as(c_int, 0x00000001);
pub const ARCHIVE_ENTRY_DIGEST_RMD160 = @as(c_int, 0x00000002);
pub const ARCHIVE_ENTRY_DIGEST_SHA1 = @as(c_int, 0x00000003);
pub const ARCHIVE_ENTRY_DIGEST_SHA256 = @as(c_int, 0x00000004);
pub const ARCHIVE_ENTRY_DIGEST_SHA384 = @as(c_int, 0x00000005);
pub const ARCHIVE_ENTRY_DIGEST_SHA512 = @as(c_int, 0x00000006);
pub const ARCHIVE_ENTRY_ACL_EXECUTE = @as(c_int, 0x00000001);
pub const ARCHIVE_ENTRY_ACL_WRITE = @as(c_int, 0x00000002);
pub const ARCHIVE_ENTRY_ACL_READ = @as(c_int, 0x00000004);
pub const ARCHIVE_ENTRY_ACL_READ_DATA = @as(c_int, 0x00000008);
pub const ARCHIVE_ENTRY_ACL_LIST_DIRECTORY = @as(c_int, 0x00000008);
pub const ARCHIVE_ENTRY_ACL_WRITE_DATA = @as(c_int, 0x00000010);
pub const ARCHIVE_ENTRY_ACL_ADD_FILE = @as(c_int, 0x00000010);
pub const ARCHIVE_ENTRY_ACL_APPEND_DATA = @as(c_int, 0x00000020);
pub const ARCHIVE_ENTRY_ACL_ADD_SUBDIRECTORY = @as(c_int, 0x00000020);
pub const ARCHIVE_ENTRY_ACL_READ_NAMED_ATTRS = @as(c_int, 0x00000040);
pub const ARCHIVE_ENTRY_ACL_WRITE_NAMED_ATTRS = @as(c_int, 0x00000080);
pub const ARCHIVE_ENTRY_ACL_DELETE_CHILD = @as(c_int, 0x00000100);
pub const ARCHIVE_ENTRY_ACL_READ_ATTRIBUTES = @as(c_int, 0x00000200);
pub const ARCHIVE_ENTRY_ACL_WRITE_ATTRIBUTES = @as(c_int, 0x00000400);
pub const ARCHIVE_ENTRY_ACL_DELETE = @as(c_int, 0x00000800);
pub const ARCHIVE_ENTRY_ACL_READ_ACL = @as(c_int, 0x00001000);
pub const ARCHIVE_ENTRY_ACL_WRITE_ACL = @as(c_int, 0x00002000);
pub const ARCHIVE_ENTRY_ACL_WRITE_OWNER = @as(c_int, 0x00004000);
pub const ARCHIVE_ENTRY_ACL_SYNCHRONIZE = __helpers.promoteIntLiteral(c_int, 0x00008000, .hex);
pub const ARCHIVE_ENTRY_ACL_PERMS_POSIX1E = (ARCHIVE_ENTRY_ACL_EXECUTE | ARCHIVE_ENTRY_ACL_WRITE) | ARCHIVE_ENTRY_ACL_READ;
pub const ARCHIVE_ENTRY_ACL_PERMS_NFS4 = (((((((((((((((ARCHIVE_ENTRY_ACL_EXECUTE | ARCHIVE_ENTRY_ACL_READ_DATA) | ARCHIVE_ENTRY_ACL_LIST_DIRECTORY) | ARCHIVE_ENTRY_ACL_WRITE_DATA) | ARCHIVE_ENTRY_ACL_ADD_FILE) | ARCHIVE_ENTRY_ACL_APPEND_DATA) | ARCHIVE_ENTRY_ACL_ADD_SUBDIRECTORY) | ARCHIVE_ENTRY_ACL_READ_NAMED_ATTRS) | ARCHIVE_ENTRY_ACL_WRITE_NAMED_ATTRS) | ARCHIVE_ENTRY_ACL_DELETE_CHILD) | ARCHIVE_ENTRY_ACL_READ_ATTRIBUTES) | ARCHIVE_ENTRY_ACL_WRITE_ATTRIBUTES) | ARCHIVE_ENTRY_ACL_DELETE) | ARCHIVE_ENTRY_ACL_READ_ACL) | ARCHIVE_ENTRY_ACL_WRITE_ACL) | ARCHIVE_ENTRY_ACL_WRITE_OWNER) | ARCHIVE_ENTRY_ACL_SYNCHRONIZE;
pub const ARCHIVE_ENTRY_ACL_ENTRY_INHERITED = __helpers.promoteIntLiteral(c_int, 0x01000000, .hex);
pub const ARCHIVE_ENTRY_ACL_ENTRY_FILE_INHERIT = __helpers.promoteIntLiteral(c_int, 0x02000000, .hex);
pub const ARCHIVE_ENTRY_ACL_ENTRY_DIRECTORY_INHERIT = __helpers.promoteIntLiteral(c_int, 0x04000000, .hex);
pub const ARCHIVE_ENTRY_ACL_ENTRY_NO_PROPAGATE_INHERIT = __helpers.promoteIntLiteral(c_int, 0x08000000, .hex);
pub const ARCHIVE_ENTRY_ACL_ENTRY_INHERIT_ONLY = __helpers.promoteIntLiteral(c_int, 0x10000000, .hex);
pub const ARCHIVE_ENTRY_ACL_ENTRY_SUCCESSFUL_ACCESS = __helpers.promoteIntLiteral(c_int, 0x20000000, .hex);
pub const ARCHIVE_ENTRY_ACL_ENTRY_FAILED_ACCESS = __helpers.promoteIntLiteral(c_int, 0x40000000, .hex);
pub const ARCHIVE_ENTRY_ACL_INHERITANCE_NFS4 = (((((ARCHIVE_ENTRY_ACL_ENTRY_FILE_INHERIT | ARCHIVE_ENTRY_ACL_ENTRY_DIRECTORY_INHERIT) | ARCHIVE_ENTRY_ACL_ENTRY_NO_PROPAGATE_INHERIT) | ARCHIVE_ENTRY_ACL_ENTRY_INHERIT_ONLY) | ARCHIVE_ENTRY_ACL_ENTRY_SUCCESSFUL_ACCESS) | ARCHIVE_ENTRY_ACL_ENTRY_FAILED_ACCESS) | ARCHIVE_ENTRY_ACL_ENTRY_INHERITED;
pub const ARCHIVE_ENTRY_ACL_TYPE_ACCESS = @as(c_int, 0x00000100);
pub const ARCHIVE_ENTRY_ACL_TYPE_DEFAULT = @as(c_int, 0x00000200);
pub const ARCHIVE_ENTRY_ACL_TYPE_ALLOW = @as(c_int, 0x00000400);
pub const ARCHIVE_ENTRY_ACL_TYPE_DENY = @as(c_int, 0x00000800);
pub const ARCHIVE_ENTRY_ACL_TYPE_AUDIT = @as(c_int, 0x00001000);
pub const ARCHIVE_ENTRY_ACL_TYPE_ALARM = @as(c_int, 0x00002000);
pub const ARCHIVE_ENTRY_ACL_TYPE_POSIX1E = ARCHIVE_ENTRY_ACL_TYPE_ACCESS | ARCHIVE_ENTRY_ACL_TYPE_DEFAULT;
pub const ARCHIVE_ENTRY_ACL_TYPE_NFS4 = ((ARCHIVE_ENTRY_ACL_TYPE_ALLOW | ARCHIVE_ENTRY_ACL_TYPE_DENY) | ARCHIVE_ENTRY_ACL_TYPE_AUDIT) | ARCHIVE_ENTRY_ACL_TYPE_ALARM;
pub const ARCHIVE_ENTRY_ACL_USER = @as(c_int, 10001);
pub const ARCHIVE_ENTRY_ACL_USER_OBJ = @as(c_int, 10002);
pub const ARCHIVE_ENTRY_ACL_GROUP = @as(c_int, 10003);
pub const ARCHIVE_ENTRY_ACL_GROUP_OBJ = @as(c_int, 10004);
pub const ARCHIVE_ENTRY_ACL_MASK = @as(c_int, 10005);
pub const ARCHIVE_ENTRY_ACL_OTHER = @as(c_int, 10006);
pub const ARCHIVE_ENTRY_ACL_EVERYONE = @as(c_int, 10107);
pub const ARCHIVE_ENTRY_ACL_STYLE_EXTRA_ID = @as(c_int, 0x00000001);
pub const ARCHIVE_ENTRY_ACL_STYLE_MARK_DEFAULT = @as(c_int, 0x00000002);
pub const ARCHIVE_ENTRY_ACL_STYLE_SOLARIS = @as(c_int, 0x00000004);
pub const ARCHIVE_ENTRY_ACL_STYLE_SEPARATOR_COMMA = @as(c_int, 0x00000008);
pub const ARCHIVE_ENTRY_ACL_STYLE_COMPACT = @as(c_int, 0x00000010);
pub const OLD_ARCHIVE_ENTRY_ACL_STYLE_EXTRA_ID = @as(c_int, 1024);
pub const OLD_ARCHIVE_ENTRY_ACL_STYLE_MARK_DEFAULT = @as(c_int, 2048);
pub const ALPM_LIST_H = "";
pub const __GLIBC_USE_LIB_EXT2 = @as(c_int, 0);
pub const __GLIBC_USE_IEC_60559_BFP_EXT = @as(c_int, 0);
pub const __GLIBC_USE_IEC_60559_BFP_EXT_C23 = @as(c_int, 0);
pub const __GLIBC_USE_IEC_60559_EXT = @as(c_int, 0);
pub const __GLIBC_USE_IEC_60559_FUNCS_EXT = @as(c_int, 0);
pub const __GLIBC_USE_IEC_60559_FUNCS_EXT_C23 = @as(c_int, 0);
pub const __GLIBC_USE_IEC_60559_TYPES_EXT = @as(c_int, 0);
pub const __need_wchar_t = "";
pub const _STDLIB_H = @as(c_int, 1);
pub const WNOHANG = @as(c_int, 1);
pub const WUNTRACED = @as(c_int, 2);
pub const WSTOPPED = @as(c_int, 2);
pub const WEXITED = @as(c_int, 4);
pub const WCONTINUED = @as(c_int, 8);
pub const WNOWAIT = __helpers.promoteIntLiteral(c_int, 0x01000000, .hex);
pub const __WNOTHREAD = __helpers.promoteIntLiteral(c_int, 0x20000000, .hex);
pub const __WALL = __helpers.promoteIntLiteral(c_int, 0x40000000, .hex);
pub const __WCLONE = __helpers.promoteIntLiteral(c_int, 0x80000000, .hex);
pub inline fn __WEXITSTATUS(status: anytype) @TypeOf((status & __helpers.promoteIntLiteral(c_int, 0xff00, .hex)) >> @as(c_int, 8)) {
    _ = &status;
    return (status & __helpers.promoteIntLiteral(c_int, 0xff00, .hex)) >> @as(c_int, 8);
}
pub inline fn __WTERMSIG(status: anytype) @TypeOf(status & @as(c_int, 0x7f)) {
    _ = &status;
    return status & @as(c_int, 0x7f);
}
pub inline fn __WSTOPSIG(status: anytype) @TypeOf(__WEXITSTATUS(status)) {
    _ = &status;
    return __WEXITSTATUS(status);
}
pub inline fn __WIFEXITED(status: anytype) @TypeOf(__WTERMSIG(status) == @as(c_int, 0)) {
    _ = &status;
    return __WTERMSIG(status) == @as(c_int, 0);
}
pub inline fn __WIFSIGNALED(status: anytype) @TypeOf((__helpers.cast(i8, (status & @as(c_int, 0x7f)) + @as(c_int, 1)) >> @as(c_int, 1)) > @as(c_int, 0)) {
    _ = &status;
    return (__helpers.cast(i8, (status & @as(c_int, 0x7f)) + @as(c_int, 1)) >> @as(c_int, 1)) > @as(c_int, 0);
}
pub inline fn __WIFSTOPPED(status: anytype) @TypeOf((status & @as(c_int, 0xff)) == @as(c_int, 0x7f)) {
    _ = &status;
    return (status & @as(c_int, 0xff)) == @as(c_int, 0x7f);
}
pub inline fn __WIFCONTINUED(status: anytype) @TypeOf(status == __W_CONTINUED) {
    _ = &status;
    return status == __W_CONTINUED;
}
pub inline fn __WCOREDUMP(status: anytype) @TypeOf(status & __WCOREFLAG) {
    _ = &status;
    return status & __WCOREFLAG;
}
pub inline fn __W_EXITCODE(ret: anytype, sig: anytype) @TypeOf((ret << @as(c_int, 8)) | sig) {
    _ = &ret;
    _ = &sig;
    return (ret << @as(c_int, 8)) | sig;
}
pub inline fn __W_STOPCODE(sig: anytype) @TypeOf((sig << @as(c_int, 8)) | @as(c_int, 0x7f)) {
    _ = &sig;
    return (sig << @as(c_int, 8)) | @as(c_int, 0x7f);
}
pub const __W_CONTINUED = __helpers.promoteIntLiteral(c_int, 0xffff, .hex);
pub const __WCOREFLAG = @as(c_int, 0x80);
pub inline fn WEXITSTATUS(status: anytype) @TypeOf(__WEXITSTATUS(status)) {
    _ = &status;
    return __WEXITSTATUS(status);
}
pub inline fn WTERMSIG(status: anytype) @TypeOf(__WTERMSIG(status)) {
    _ = &status;
    return __WTERMSIG(status);
}
pub inline fn WSTOPSIG(status: anytype) @TypeOf(__WSTOPSIG(status)) {
    _ = &status;
    return __WSTOPSIG(status);
}
pub inline fn WIFEXITED(status: anytype) @TypeOf(__WIFEXITED(status)) {
    _ = &status;
    return __WIFEXITED(status);
}
pub inline fn WIFSIGNALED(status: anytype) @TypeOf(__WIFSIGNALED(status)) {
    _ = &status;
    return __WIFSIGNALED(status);
}
pub inline fn WIFSTOPPED(status: anytype) @TypeOf(__WIFSTOPPED(status)) {
    _ = &status;
    return __WIFSTOPPED(status);
}
pub inline fn WIFCONTINUED(status: anytype) @TypeOf(__WIFCONTINUED(status)) {
    _ = &status;
    return __WIFCONTINUED(status);
}
pub const __ldiv_t_defined = @as(c_int, 1);
pub const __lldiv_t_defined = @as(c_int, 1);
pub const RAND_MAX = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const EXIT_FAILURE = @as(c_int, 1);
pub const EXIT_SUCCESS = @as(c_int, 0);
pub const MB_CUR_MAX = __ctype_get_mb_cur_max();
pub const _ALLOCA_H = @as(c_int, 1);
pub const __COMPAR_FN_T = "";
pub const FREELIST = @compileError("unable to translate C expr: unexpected token 'do'"); // /usr/include/alpm_list.h:61:9
pub const timeval = struct_timeval;
pub const timespec = struct_timespec;
pub const __pthread_internal_list = struct___pthread_internal_list;
pub const __pthread_internal_slist = struct___pthread_internal_slist;
pub const __pthread_mutex_s = struct___pthread_mutex_s;
pub const __pthread_rwlock_arch_t = struct___pthread_rwlock_arch_t;
pub const __pthread_cond_s = struct___pthread_cond_s;
pub const _G_fpos_t = struct__G_fpos_t;
pub const _G_fpos64_t = struct__G_fpos64_t;
pub const _IO_marker = struct__IO_marker;
pub const _IO_FILE = struct__IO_FILE;
pub const _IO_codecvt = struct__IO_codecvt;
pub const _IO_wide_data = struct__IO_wide_data;
pub const _IO_cookie_io_functions_t = struct__IO_cookie_io_functions_t;
pub const tm = struct_tm;
pub const itimerspec = struct_itimerspec;
pub const sigevent = struct_sigevent;
pub const __locale_struct = struct___locale_struct;
pub const archive = struct_archive;
pub const archive_entry = struct_archive_entry;
pub const archive_acl = struct_archive_acl;
pub const archive_entry_linkresolver = struct_archive_entry_linkresolver;
pub const random_data = struct_random_data;
pub const drand48_data = struct_drand48_data;
pub const _alpm_list_t = struct__alpm_list_t;
pub const _alpm_handle_t = struct__alpm_handle_t;
pub const _alpm_db_t = struct__alpm_db_t;
pub const _alpm_pkg_t = struct__alpm_pkg_t;
pub const _alpm_pkg_xdata_t = struct__alpm_pkg_xdata_t;
pub const _alpm_file_t = struct__alpm_file_t;
pub const _alpm_filelist_t = struct__alpm_filelist_t;
pub const _alpm_backup_t = struct__alpm_backup_t;
pub const _alpm_group_t = struct__alpm_group_t;
pub const _alpm_errno_t = enum__alpm_errno_t;
pub const _alpm_siglevel_t = enum__alpm_siglevel_t;
pub const _alpm_sigstatus_t = enum__alpm_sigstatus_t;
pub const _alpm_sigvalidity_t = enum__alpm_sigvalidity_t;
pub const _alpm_pgpkey_t = struct__alpm_pgpkey_t;
pub const _alpm_sigresult_t = struct__alpm_sigresult_t;
pub const _alpm_siglist_t = struct__alpm_siglist_t;
pub const _alpm_depmod_t = enum__alpm_depmod_t;
pub const _alpm_fileconflicttype_t = enum__alpm_fileconflicttype_t;
pub const _alpm_depend_t = struct__alpm_depend_t;
pub const _alpm_depmissing_t = struct__alpm_depmissing_t;
pub const _alpm_conflict_t = struct__alpm_conflict_t;
pub const _alpm_fileconflict_t = struct__alpm_fileconflict_t;
pub const _alpm_event_type_t = enum__alpm_event_type_t;
pub const _alpm_event_any_t = struct__alpm_event_any_t;
pub const _alpm_package_operation_t = enum__alpm_package_operation_t;
pub const _alpm_event_package_operation_t = struct__alpm_event_package_operation_t;
pub const _alpm_event_optdep_removal_t = struct__alpm_event_optdep_removal_t;
pub const _alpm_event_scriptlet_info_t = struct__alpm_event_scriptlet_info_t;
pub const _alpm_event_database_missing_t = struct__alpm_event_database_missing_t;
pub const _alpm_event_pkgdownload_t = struct__alpm_event_pkgdownload_t;
pub const _alpm_event_pacnew_created_t = struct__alpm_event_pacnew_created_t;
pub const _alpm_event_pacsave_created_t = struct__alpm_event_pacsave_created_t;
pub const _alpm_hook_when_t = enum__alpm_hook_when_t;
pub const _alpm_event_hook_t = struct__alpm_event_hook_t;
pub const _alpm_event_hook_run_t = struct__alpm_event_hook_run_t;
pub const _alpm_event_pkg_retrieve_t = struct__alpm_event_pkg_retrieve_t;
pub const _alpm_event_t = union__alpm_event_t;
pub const _alpm_question_type_t = enum__alpm_question_type_t;
pub const _alpm_question_any_t = struct__alpm_question_any_t;
pub const _alpm_question_install_ignorepkg_t = struct__alpm_question_install_ignorepkg_t;
pub const _alpm_question_replace_t = struct__alpm_question_replace_t;
pub const _alpm_question_conflict_t = struct__alpm_question_conflict_t;
pub const _alpm_question_corrupted_t = struct__alpm_question_corrupted_t;
pub const _alpm_question_remove_pkgs_t = struct__alpm_question_remove_pkgs_t;
pub const _alpm_question_select_provider_t = struct__alpm_question_select_provider_t;
pub const _alpm_question_import_key_t = struct__alpm_question_import_key_t;
pub const _alpm_question_t = union__alpm_question_t;
pub const _alpm_progress_t = enum__alpm_progress_t;
pub const _alpm_download_event_type_t = enum__alpm_download_event_type_t;
pub const _alpm_download_event_init_t = struct__alpm_download_event_init_t;
pub const _alpm_download_event_progress_t = struct__alpm_download_event_progress_t;
pub const _alpm_download_event_retry_t = struct__alpm_download_event_retry_t;
pub const _alpm_download_event_completed_t = struct__alpm_download_event_completed_t;
pub const _alpm_db_usage_t = enum__alpm_db_usage_t;
pub const _alpm_loglevel_t = enum__alpm_loglevel_t;
pub const _alpm_pkgreason_t = enum__alpm_pkgreason_t;
pub const _alpm_pkgfrom_t = enum__alpm_pkgfrom_t;
pub const _alpm_pkgvalidation_t = enum__alpm_pkgvalidation_t;
pub const _alpm_transflag_t = enum__alpm_transflag_t;
pub const alpm_caps = enum_alpm_caps;
