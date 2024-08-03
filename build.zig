const std = @import("std");

const rmq_version: std.SemanticVersion = .{
    .major = 0,
    .minor = 15,
    .patch = 0,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bindings = b.option(bool, "bindings", "Use zig module") orelse false;
    const examples = b.option(bool, "examples", "Build examples") orelse false;
    const shared = b.option(bool, "shared", "Build shared library") orelse false;
    const ssl = b.option(bool, "ssl", "Build with SSL support") orelse false;

    const generated_export_header = b.addWriteFile("rabbitmq-c/export.h", export_h);

    const lib = if (shared) b.addSharedLibrary(.{
        .name = "rabbitmq-c",
        .target = target,
        .optimize = optimize,
        .version = rmq_version,
    }) else b.addStaticLibrary(.{
        .name = "rabbitmq-c-static",
        .target = target,
        .optimize = optimize,
        .version = rmq_version,
    });
    if (!shared) {
        lib.pie = true;
        lib.defineCMacro("AMQP_STATIC", "");
    }
    const configH = b.addConfigHeader(.{
        .style = .blank,
        .include_path = "config.h",
    }, .{
        .HAVE_SELECT = if (lib.rootModuleTarget().os.tag == .windows) {} else null,
        .HAVE_POLL = if (lib.rootModuleTarget().os.tag != .windows) {} else null,
        .AMQ_PLATFORM = switch (lib.rootModuleTarget().os.tag) {
            .linux => "Linux",
            .macos => "Darwin",
            .windows => "Win32",
            else => @panic("Unsupported platform"),
        },
        .ENABLE_SSL_ENGINE_API = if (ssl) {} else null,
    });
    lib.defineCMacro("HAVE_CONFIG_H", null);
    lib.addConfigHeader(configH);
    lib.addIncludePath(generated_export_header.getDirectory());
    lib.addIncludePath(b.path("include"));
    lib.addIncludePath(b.path("librabbitmq"));
    if (lib.rootModuleTarget().os.tag == .windows) {
        lib.addIncludePath(b.path("librabbitmq/win32"));
        lib.addCSourceFile(.{
            .file = b.path("librabbitmq/win32/threads.c"),
        });
        lib.linkSystemLibrary("ws2_32");
    } else lib.addIncludePath(b.path("librabbitmq/unix"));
    lib.addCSourceFiles(.{
        .root = b.path("librabbitmq"),
        .files = &.{
            "amqp_api.c",  "amqp_connection.c", "amqp_consumer.c", "amqp_framing.c",
            "amqp_mem.c",  "amqp_socket.c",     "amqp_table.c",    "amqp_tcp_socket.c",
            "amqp_time.c", "amqp_url.c",
        },
    });
    if (ssl) {
        lib.addCSourceFiles(.{
            .root = b.path("librabbitmq"),
            .files = &.{
                "amqp_openssl.c",
                "amqp_openssl_bio.c",
            },
        });
        lib.linkSystemLibrary("ssl");
        lib.linkSystemLibrary("crypto");
    }
    lib.linkLibC();
    lib.installHeadersDirectory(b.path("include"), "", .{});

    if (bindings) {
        const module_rmq = b.addModule("rabbitmq", .{
            .root_source_file = b.path("bindings/rmq.zig"),
            .link_libc = true,
        });
        for (lib.root_module.include_dirs.items) |include_dir| {
            module_rmq.include_dirs.append(b.allocator, include_dir) catch unreachable;
        }
        module_rmq.linkLibrary(lib);
    } else b.installArtifact(lib);

    if (examples) {
        inline for (&.{
            "amqp_bind.c",
            if (ssl)
                "amqp_ssl_connect.c"
            else
                "amqp_connect_timeout.c",
            "amqp_consumer.c",
            "amqp_exchange_declare.c",
            "amqp_listen.c",
            "amqp_listenq.c",
            "amqp_producer.c",
            "amqp_rpc_sendstring_client.c",
            "amqp_sendstring.c",
            "amqp_unbind.c",
        }) |file| {
            buildExamples(b, .{
                .name = file[0 .. file.len - 2],
                .filepaths = &.{file},
                .target = target,
                .optimize = optimize,
                .lib = lib,
            });
        }
    }
}

const buildOptions = struct {
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    filepaths: []const []const u8,
    lib: *std.Build.Step.Compile,
};

fn buildExamples(b: *std.Build, options: buildOptions) void {
    const example = b.addExecutable(.{
        .name = options.name,
        .target = options.target,
        .optimize = options.optimize,
    });
    for (options.lib.root_module.include_dirs.items) |include_dir| {
        example.root_module.include_dirs.append(b.allocator, include_dir) catch unreachable;
    }
    example.addIncludePath(b.path("examples"));
    example.addCSourceFile(.{
        .file = b.path("examples/utils.c"),
    });
    if (example.rootModuleTarget().os.tag == .windows)
        example.addCSourceFile(.{
            .file = b.path("examples/win32/platform_utils.c"),
        })
    else
        example.addCSourceFile(.{
            .file = b.path("examples/unix/platform_utils.c"),
        });
    example.addCSourceFiles(.{
        .root = b.path("examples"),
        .files = options.filepaths,
    });
    example.linkLibrary(options.lib);
    example.linkLibC();
    b.installArtifact(example);

    const run_cmd = b.addRunArtifact(example);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step(options.name, b.fmt("Run the {s} example", .{options.name}));
    run_step.dependOn(&run_cmd.step);
}

const export_h =
    \\ #ifndef RABBITMQ_C_EXPORT_H
    \\ #define RABBITMQ_C_EXPORT_H
    \\
    \\ #ifdef AMQP_STATIC
    \\ #  define AMQP_EXPORT
    \\ #  define AMQP_NO_EXPORT
    \\ #else
    \\ #  ifndef AMQP_EXPORT
    \\ #    ifdef rabbitmq_EXPORTS
    \\    /* We are building this library */
    \\ #      define AMQP_EXPORT __attribute__((visibility("default")))
    \\ #    else
    \\    /* We are using this library */
    \\ #      define AMQP_EXPORT __attribute__((visibility("default")))
    \\ #    endif
    \\ #  endif
    \\
    \\ #  ifndef AMQP_NO_EXPORT
    \\ #    define AMQP_NO_EXPORT __attribute__((visibility("hidden")))
    \\ #  endif
    \\ #endif
    \\
    \\ #ifndef AMQP_DEPRECATED
    \\ #  define AMQP_DEPRECATED __attribute__ ((__deprecated__))
    \\ #endif
    \\
    \\ #ifndef AMQP_DEPRECATED_EXPORT
    \\ #  define AMQP_DEPRECATED_EXPORT AMQP_EXPORT AMQP_DEPRECATED
    \\ #endif
    \\
    \\ #ifndef AMQP_DEPRECATED_NO_EXPORT
    \\ #  define AMQP_DEPRECATED_NO_EXPORT AMQP_NO_EXPORT AMQP_DEPRECATED
    \\ #endif
    \\
    \\/* NOLINTNEXTLINE(readability-avoid-unconditional-preprocessor-if) */
    \\ #if 0 /* DEFINE_NO_DEPRECATED */
    \\ #  ifndef AMQP_NO_DEPRECATED
    \\ #    define AMQP_NO_DEPRECATED
    \\ #  endif
    \\ #endif
    \\
    \\ #endif /* RABBITMQ_C_EXPORT_H */
    \\
;
