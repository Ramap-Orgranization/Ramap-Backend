import assert from "node:assert/strict";
import test from "node:test";
import { deleteCurrentAccount, handleAuthenticatedDeletion } from "./handler.ts";

const userId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

test("사진 삭제 실패 시 Auth 계정을 삭제하지 않고 재시도를 허용한다", async () => {
    const fixture = clients({});
    fixture.service.cleanupMedia = async () => false;
    const result = await deleteCurrentAccount(userId, fixture.account, fixture.service);
    assert.equal(result.status, 503);
    assert.equal(fixture.deletedUser(), null);
});

function clients(objectsByBucket, options = {}) {
    const removed = [];
    let deletedUser = null;
    const account = { rpc: async () => ({ error: options.fenceError ?? null }) };
    const service = {
        async rpc(name, parameters) {
            assert.equal(name, "list_account_owned_storage");
            assert.deepEqual(parameters, { p_user_id: userId });
            return {
                data: Object.entries(objectsByBucket).flatMap(([bucket, objects]) =>
                    objects.map((object) => ({ bucket_id: bucket, name: `${userId}/${object.name}` })),
                ),
                error: null,
            };
        },
        storage: {
            from(bucket) {
                return {
                    async list(prefix, listOptions) {
                        assert.equal(prefix, userId);
                        return { data: (objectsByBucket[bucket] ?? []).slice(listOptions.offset, listOptions.offset + listOptions.limit), error: options.listError ?? null };
                    },
                    async remove(paths) {
                        if (options.removeError) return { error: options.removeError };
                        removed.push([bucket, ...paths]);
                        const names = new Set(paths.map((path) => path.slice(`${userId}/`.length)));
                        objectsByBucket[bucket] = (objectsByBucket[bucket] ?? []).filter((object) => !names.has(object.name));
                        return { error: null };
                    },
                };
            },
        },
        auth: { admin: { async deleteUser(id) { deletedUser = id; return { error: options.deleteError ?? null }; } } },
    };
    return { account, service, removed, deletedUser: () => deletedUser };
}

test("deletes every object under both account prefixes before deleting auth", async () => {
    const fixture = clients({
        "shop-review-images": [{ name: "one.jpg" }, { name: "two.png" }],
        "profile-avatars": [{ name: "avatar.jpg" }],
    });
    const result = await deleteCurrentAccount(userId, fixture.account, fixture.service);
    assert.deepEqual(result, { status: 200, body: { deleted: true } });
    assert.equal(fixture.deletedUser(), userId);
    assert.deepEqual(fixture.removed, [
        ["shop-review-images", `${userId}/one.jpg`, `${userId}/two.png`],
        ["profile-avatars", `${userId}/avatar.jpg`],
    ]);
});

test("leaves the deletion fence and skips auth deletion when storage removal fails", async () => {
    const fixture = clients({ "shop-review-images": [{ name: "one.jpg" }], "profile-avatars": [] }, { removeError: { message: "offline" } });
    const result = await deleteCurrentAccount(userId, fixture.account, fixture.service);
    assert.deepEqual(result, { status: 503, body: { code: "account_deletion_failed" } });
    assert.equal(fixture.deletedUser(), null);
});

test("rejects missing authentication and non-POST requests before touching the account", async () => {
    const fixture = clients({ "shop-review-images": [], "profile-avatars": [] });
    assert.deepEqual(await handleAuthenticatedDeletion("GET", userId, fixture.account, fixture.service), {
        status: 405, body: { code: "method_not_allowed" },
    });
    assert.deepEqual(await handleAuthenticatedDeletion("POST", null, fixture.account, fixture.service), {
        status: 401, body: { code: "authentication_required" },
    });
    assert.equal(fixture.deletedUser(), null);
});

test("removes every storage page and succeeds on a fenced retry", async () => {
    const images = Array.from({ length: 1_001 }, (_, index) => ({ name: `${index}.jpg` }));
    const options = { removeError: { message: "temporary" } };
    const fixture = clients({ "shop-review-images": images, "profile-avatars": [] }, options);
    assert.equal((await deleteCurrentAccount(userId, fixture.account, fixture.service)).status, 503);
    options.removeError = null;
    assert.deepEqual(await deleteCurrentAccount(userId, fixture.account, fixture.service), { status: 200, body: { deleted: true } });
    assert.equal(fixture.deletedUser(), userId);
    assert.equal(fixture.removed.filter((entry) => entry[0] === "shop-review-images").length, 2);
});
