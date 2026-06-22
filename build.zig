const std = @import("std");

// Build for the wayland library.
//
// This package is abstract, like libwayland: it provides the wire protocol,
// connection/object/event machinery, shm helpers, and a protocol-binding
// generator, but it bakes in no specific protocol (no wl_compositor, no
// xdg-shell). Consumers generate the protocol modules they need from XML via
// the exposed `generateProtocol` helper.
//
// Exposes one module, `wayland`, with the pieces as namespaces:
//   wayland.wire / wayland.fixed - core wire layer
//   wayland.shm                  - shm pool + SCM_RIGHTS fd passing
//   wayland.client / wayland.server - abstract client/server scaffolding
//   wayland-gen                  - the protocol scanner executable (artifact)
//   generateProtocol(owner, dep, xml, name) -> *Module  - the easy helper

/// Turn any Wayland protocol XML file into an importable Zig bindings module.
/// Consumers call this from their own build.zig:
///
///   const wl = b.dependency("wayland", .{});
///   const xdg = @import("wayland").generateProtocol(b, wl, xdg_xml, "xdg");
///   my_module.addImport("xdg", xdg);
///
/// The generated module imports the abstract `core` wire layer as "core".
pub fn generateProtocol(
    owner: *std.Build,
    wayland_dep: *std.Build.Dependency,
    protocol_xml: std.Build.LazyPath,
    module_name: []const u8,
) *std.Build.Module {
    const run = owner.addRunArtifact(wayland_dep.artifact("wayland-gen"));
    run.addFileArg(protocol_xml);
    const out = run.addOutputFileArg(owner.fmt("{s}.zig", .{module_name}));
    const mod = owner.createModule(.{ .root_source_file = out });
    // Generated bindings import the core wire layer as "core" (the wayland module).
    mod.addImport("wayland", wayland_dep.module("wayland"));
    return mod;
}

/// Run the in-tree generator on a vendored protocol XML (a path relative to
/// this build root) and return an importable module of its bindings. Used for
/// this package's own tests/example, distinct from generateProtocol (which is
/// the public helper for downstream consumers that depend on this package).
fn generateLocalProtocol(
    b: *std.Build,
    gen_exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    xml_rel_path: []const u8,
    module_name: []const u8,
) *std.Build.Module {
    const run = b.addRunArtifact(gen_exe);
    run.addFileArg(b.path(xml_rel_path));
    const out = run.addOutputFileArg(b.fmt("{s}.zig", .{module_name}));
    const mod = b.createModule(.{
        .root_source_file = out,
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("wayland", b.modules.get("wayland").?);
    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xml_dep = b.dependency("xml", .{ .target = target, .optimize = optimize });
    const xml_mod = xml_dep.module("xml");

    const root_module = b.addModule("wayland", .{
        .root_source_file = b.path("src/wayland.zig"),
        .target = target,
        .optimize = optimize,
    });

    const host_gen_exe = b.addExecutable(.{
        .name = "wayland-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("generator/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    host_gen_exe.root_module.addImport("xml", xml_mod);

    const gen_exe = b.addExecutable(.{
        .name = "wayland-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("generator/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gen_exe.root_module.addImport("xml", xml_mod);
    b.installArtifact(gen_exe);

    const test_step = b.step("test", "Run tests");

    const wl_tests = b.addTest(.{ .root_module = root_module });
    test_step.dependOn(&b.addRunArtifact(wl_tests).step);

    const wayland_dep = b.dependency("wayland", .{});
    const gen_check = b.addRunArtifact(host_gen_exe);
    gen_check.addFileArg(wayland_dep.path("protocol/wayland.xml"));

    const gen_check_out = gen_check.addOutputFileArg("wayland_protocol.zig");
    const gen_check_mod = b.createModule(.{
        .root_source_file = gen_check_out,
        .target = target,
        .optimize = optimize,
    });
    gen_check_mod.addImport("wayland", b.modules.get("wayland").?);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = gen_check_mod })).step);

    const gen_proto = b.addRunArtifact(gen_exe);
    gen_proto.addFileArg(wayland_dep.path("protocol/wayland.xml"));

    const gen_proto_out = gen_proto.addOutputFileArg("wayland_protocol.zig");
    const gen_proto_mod = b.createModule(.{
        .root_source_file = gen_proto_out,
        .target = target,
        .optimize = optimize,
    });
    gen_proto_mod.addImport("wayland", b.modules.get("wayland").?);

    const roundtrip_mod = b.createModule(.{
        .root_source_file = b.path("test/generated_server_roundtrip.zig"),
        .target = target,
        .optimize = optimize,
    });
    roundtrip_mod.addImport("wayland", b.modules.get("wayland").?);
    roundtrip_mod.addImport("wayland_protocol", gen_proto_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = roundtrip_mod })).step);

    // Server-side wl_shm tests: drive the Shm(Protocol) helper over the
    // generated wl_shm/wl_shm_pool/wl_buffer bindings (create_pool via a memfd
    // over SCM_RIGHTS + create_buffer bounds/format checks).
    const shm_test_mod = b.createModule(.{
        .root_source_file = b.path("test/shm_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    shm_test_mod.addImport("wayland", b.modules.get("wayland").?);
    shm_test_mod.addImport("wayland_protocol", gen_proto_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = shm_test_mod })).step);

    // color-management-v1: the Wayland HDR signaling layer.
    //
    // Generate the bindings from the vendored protocol/color-management-v1.xml,
    // compile-check them under forced analysis, and drive the ColorManager(CM)
    // helper end to end (a client negotiating PQ + Rec.2020 HDR).
    const cm_mod = generateLocalProtocol(b, host_gen_exe, target, optimize, "protocol/color-management-v1.xml", "color_management");

    // Forced-analysis compile check: refAllDecls pulls every generated decl.
    const cm_check_mod = b.createModule(.{
        .root_source_file = b.path("test/color_management_compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    cm_check_mod.addImport("color_management_protocol", cm_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cm_check_mod })).step);

    // The ColorManager server helper, driven over the generated bindings via a
    // real Display/Client roundtrip (advertise, parametric create -> ready,
    // per-surface set_image_description).
    const cm_test_mod = b.createModule(.{
        .root_source_file = b.path("test/color_management_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    cm_test_mod.addImport("wayland", b.modules.get("wayland").?);
    cm_test_mod.addImport("wayland_protocol", gen_proto_mod);
    cm_test_mod.addImport("color_management_protocol", cm_mod);
    // The ColorManager helper now lives with the example (a protocol-specific
    // helper, not part of the abstract library); the test drives it from there.
    const cm_helper_mod = b.createModule(.{
        .root_source_file = b.path("example/color_management.zig"),
        .target = target,
        .optimize = optimize,
    });
    cm_helper_mod.addImport("wayland", b.modules.get("wayland").?);
    cm_test_mod.addImport("color_management", cm_helper_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cm_test_mod })).step);

    addExampleAndTools(b, target, optimize, wayland_dep, host_gen_exe);
}

/// Build the example server (uses the generated wayland.xml stubs for
/// wl_compositor / wl_shm / wl_output / wl_seat) and the Zig wayland-info client.
fn addExampleAndTools(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wayland_dep: *std.Build.Dependency,
    host_gen_exe: *std.Build.Step.Compile,
) void {
    // Generate the wayland.xml bindings module for the example to consume.
    const gen_ex = b.addRunArtifact(host_gen_exe);
    gen_ex.addFileArg(wayland_dep.path("protocol/wayland.xml"));
    const gen_ex_out = gen_ex.addOutputFileArg("wayland_protocol.zig");
    const ex_proto_mod = b.createModule(.{
        .root_source_file = gen_ex_out,
        .target = target,
        .optimize = optimize,
    });
    ex_proto_mod.addImport("wayland", b.modules.get("wayland").?);

    const example = b.addExecutable(.{
        .name = "wl-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // The color-management-v1 bindings for the example server (HDR signaling).
    const ex_cm_mod = generateLocalProtocol(b, host_gen_exe, target, optimize, "protocol/color-management-v1.xml", "color_management");

    example.root_module.addImport("wayland", b.modules.get("wayland").?);
    example.root_module.addImport("wayland_protocol", ex_proto_mod);
    example.root_module.addImport("color_management_protocol", ex_cm_mod);
    b.installArtifact(example);

    const example_step = b.step("example", "Build the example Wayland server");
    example_step.dependOn(&example.step);

    // The client dual of the example server: a Zig reimplementation of
    // wayland-info that connects to a running server and enumerates its globals
    // + shm formats + output modes + seat caps, using this library's client
    // side and the same generated wayland.xml bindings. Reuses ex_proto_mod.
    const wl_info = b.addExecutable(.{
        .name = "wayland-info",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/wayland-info.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    wl_info.root_module.addImport("wayland", b.modules.get("wayland").?);
    wl_info.root_module.addImport("wayland_protocol", ex_proto_mod);
    wl_info.root_module.addImport("color_management_protocol", ex_cm_mod);
    b.installArtifact(wl_info);

    const wl_info_step = b.step("wayland-info", "Build the Zig wayland-info client");
    wl_info_step.dependOn(&wl_info.step);
}
