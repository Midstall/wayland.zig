//! Forced-analysis compile check for the generated color-management-v1 bindings.
//! refAllDecls pulls every interface namespace (enums, interface tables, event
//! senders, Implementation, dispatch, setImplementation) into analysis, so this
//! test failing to compile means the generator emitted invalid Zig for this
//! protocol. It asserts the HDR-relevant enum values landed correctly.

const std = @import("std");
const cm = @import("color_management_protocol");

/// Force analysis of every generated interface namespace AND its functions
/// (event senders, dispatch, setImplementation). refAllDecls is shallow, so we
/// descend one level into each interface struct to pull its methods in.
fn refInterface(comptime T: type) void {
    std.testing.refAllDecls(T);
}

test "color-management-v1 bindings compile under forced analysis" {
    std.testing.refAllDecls(cm);
    refInterface(cm.WpColorManagerV1);
    refInterface(cm.WpColorManagementOutputV1);
    refInterface(cm.WpColorManagementSurfaceV1);
    refInterface(cm.WpColorManagementSurfaceFeedbackV1);
    refInterface(cm.WpImageDescriptionCreatorIccV1);
    refInterface(cm.WpImageDescriptionCreatorParamsV1);
    refInterface(cm.WpImageDescriptionV1);
    refInterface(cm.WpImageDescriptionInfoV1);
    refInterface(cm.WpImageDescriptionReferenceV1);
}

test "color-management-v1 HDR enum values are correct" {
    // The HDR transfer functions + primaries a client negotiates.
    try std.testing.expectEqual(@as(u32, 11), @intFromEnum(cm.WpColorManagerV1.TransferFunction.st2084_pq));
    try std.testing.expectEqual(@as(u32, 13), @intFromEnum(cm.WpColorManagerV1.TransferFunction.hlg));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(cm.WpColorManagerV1.Primaries.bt2020));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(cm.WpColorManagerV1.Feature.parametric));
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(cm.WpColorManagerV1.RenderIntent.perceptual));

    // The since=2 events exist as senders.
    try std.testing.expect(@hasDecl(cm.WpImageDescriptionV1, "sendReady2"));
    try std.testing.expect(@hasDecl(cm.WpImageDescriptionV1, "sendReady"));
    try std.testing.expect(@hasDecl(cm.WpImageDescriptionV1, "sendFailed"));

    // The manager advertises via these senders.
    try std.testing.expect(@hasDecl(cm.WpColorManagerV1, "sendSupportedIntent"));
    try std.testing.expect(@hasDecl(cm.WpColorManagerV1, "sendSupportedFeature"));
    try std.testing.expect(@hasDecl(cm.WpColorManagerV1, "sendSupportedTfNamed"));
    try std.testing.expect(@hasDecl(cm.WpColorManagerV1, "sendSupportedPrimariesNamed"));
    try std.testing.expect(@hasDecl(cm.WpColorManagerV1, "sendDone"));
}
