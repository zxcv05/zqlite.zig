const std = @import("std");
const zqlite = @import("zqlite.zig");

const Conn = zqlite.Conn;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

pub const Pool = struct {
    conns: []Conn,
    available: usize,
    mutex: Thread.Mutex,
    cond: Thread.Condition,
    allocator: Allocator,

    pub const Config = struct {
        size: usize = 5,
        flags: c_int = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode,
        path: [*:0]const u8,
        on_connection: ?*const fn (conn: Conn) anyerror!void = null,
        on_first_connection: ?*const fn (conn: Conn) anyerror!void = null,
    };

    pub fn init(allocator: Allocator, config: Config) !*Pool {
        const pool = try allocator.create(Pool);
        errdefer allocator.destroy(pool);

        const size = config.size;
        const conns = try allocator.alloc(Conn, size);
        errdefer allocator.free(conns);

        pool.* = .{
            .cond = .{},
            .mutex = .{},
            .conns = conns,
            .available = size,
            .allocator = allocator,
        };

        const path = config.path;
        const flags = config.flags;
        const on_connection = config.on_connection;

        var init_count: usize = 0;
        errdefer {
            for (0..init_count) |i| {
                conns[i].close();
            }
        }

        for (0..size) |i| {
            var conn = try Conn.init(path, flags);
            conn._pool = pool;

            init_count += 1;
            if (i == 0) {
                if (config.on_first_connection) |f| {
                    try f(conn);
                }
            }
            if (on_connection) |f| {
                try f(conn);
            }
            conns[i] = conn;
        }

        return pool;
    }

    pub fn deinit(self: *Pool) void {
        const allocator = self.allocator;
        for (self.conns) |conn| {
            conn.close();
        }
        allocator.free(self.conns);
        allocator.destroy(self);
    }

    pub fn acquire(self: *Pool) Conn {
        self.mutex.lock();

        while (true) {
            if (self.available == 0) {
                self.cond.wait(&self.mutex);
                continue;
            }

            const index = self.available - 1;
            const conn = self.conns[index];

            self.available = index;
            self.mutex.unlock();

            return conn;
        }
    }

    pub fn release(self: *Pool, conn: Conn) void {
        defer self.cond.signal();

        self.mutex.lock();
        defer self.mutex.unlock();

        self.conns[self.available] = conn;
        self.available += 1;
    }
};

const t = std.testing;
test "pool" {
    var pool = try Pool.init(t.allocator, .{
        .size = 4,
        .path = "/tmp/zqlite.test",
        .on_connection = &testPoolEachConnection,
        .on_first_connection = &testPoolFirstConnection,
    });
    defer pool.deinit();

    var threads: [12]std.Thread = undefined;
    for (threads[0..]) |*thread| {
        thread.* = try std.Thread.spawn(.{}, testPool, .{pool});
    }

    for (threads[0..]) |thread| {
        thread.join();
    }

    const c1 = pool.acquire();
    defer c1.release();

    const row = (try c1.row("select cnt from pool_test", .{})).?;
    try t.expectEqual(@as(i64, 1000 * threads.len), row.int(0));
    row.deinit();

    try c1.execNoArgs("drop table pool_test");
}

fn testPool(p: *Pool) void {
    for (0..1000) |_| {
        const conn = p.acquire();
        defer conn.release();

        conn.execNoArgs("update pool_test set cnt = cnt + 1") catch |err| {
            std.debug.print("update err: {any}\n", .{err});
            unreachable;
        };
    }
}

fn testPoolFirstConnection(conn: Conn) !void {
    try conn.execNoArgs("pragma journal_mode=wal");

    // This is not safe and can result in corruption. This is only set
    // because the tests might be run on really slow hardware and we
    // want to avoid having a busy timeout.
    try conn.execNoArgs("pragma synchronous=off");

    try conn.execNoArgs("drop table if exists pool_test");
    try conn.execNoArgs("create table pool_test (cnt int not null)");
    try conn.execNoArgs("insert into pool_test (cnt) values (0)");
}

fn testPoolEachConnection(conn: Conn) !void {
    return conn.busyTimeout(5000);
}
