const std = @import("std");
const profile_paths = @import("../shared/profile_paths.zig");
const subscription_session = @import("subscription_session.zig");

const store = subscription_session.Store(.{
    .auth_file_name = profile_paths.chatgpt_auth_file_name,
    .mutation_lock_file_name = "chatgpt-auth.lock",
    .trace_label = "ChatGPT",
    .validate_account_id_on_save = false,
}, error.InvalidChatGptAuthSession, error.ChatGptOAuthUnavailable);

pub const Session = store.Session;
pub const Mutation = store.Mutation;
pub const DeleteOutcome = subscription_session.DeleteOutcome;
pub const presence = store.presence;
pub const requireSignInStorage = store.requireSignInStorage;
pub const refreshDeadlineMs = subscription_session.refreshDeadlineMs;
pub const load = store.load;
pub const saveNewSession = store.saveNewSession;
pub const beginExistingMutation = store.beginExistingMutation;

test "ChatGPT auth session rejects account identifiers unsafe for HTTP headers" {
    var session = store.parse(
        std.testing.allocator,
        "{\"version\":1,\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_at_ms\":1000,\"account_id\":\"acct\\r\\ninjected\"}",
    ) catch |err| {
        try std.testing.expectEqual(error.InvalidChatGptAuthSession, err);
        return;
    };
    defer session.deinit(std.testing.allocator);
    return error.TestExpectedInvalidChatGptAuthSession;
}
