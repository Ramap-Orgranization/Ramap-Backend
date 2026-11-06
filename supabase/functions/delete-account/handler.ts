export type GatewayError = { message: string } | null;

export type AccountClient = {
    rpc(name: string): PromiseLike<{ error: GatewayError }>;
};

export type StorageClient = {
    list(prefix: string, options: { limit: number; offset: number }): Promise<{ data: Array<{ name: string }> | null; error: GatewayError }>;
    remove(paths: string[]): Promise<{ error: GatewayError }>;
};

export type ServiceClient = {
    cleanupMedia?: () => Promise<boolean>;
    storage: { from(bucket: string): StorageClient };
    auth: { admin: { deleteUser(userId: string): Promise<{ error: GatewayError }> } };
    rpc(name: string, parameters: { p_user_id: string }): PromiseLike<{ data: Array<{ bucket_id: string; name: string }> | null; error: GatewayError }>;
};

export type AccountDeletionResult =
    | { status: 200; body: { deleted: true } }
    | { status: 503; body: { code: "account_deletion_failed" } };

const PAGE_SIZE = 1_000;

export async function handleAuthenticatedDeletion(
    method: string,
    userId: string | null,
    accountClient: AccountClient,
    serviceClient: ServiceClient,
): Promise<AccountDeletionResult | { status: 401 | 405; body: { code: "authentication_required" | "method_not_allowed" } }> {
    if (method !== "POST") return { status: 405, body: { code: "method_not_allowed" } };
    if (userId === null) return { status: 401, body: { code: "authentication_required" } };
    return deleteCurrentAccount(userId, accountClient, serviceClient);
}

export async function deleteCurrentAccount(
    userId: string,
    accountClient: AccountClient,
    serviceClient: ServiceClient,
): Promise<AccountDeletionResult> {
    const { error: fenceError } = await accountClient.rpc("begin_current_user_deletion");
    if (fenceError) return failure();

    if (serviceClient.cleanupMedia && !await serviceClient.cleanupMedia()) return failure();
    if (!await removeAllOwnedObjects(serviceClient, userId)) return failure();

    const { error: deleteError } = await serviceClient.auth.admin.deleteUser(userId);
    return deleteError ? failure() : { status: 200, body: { deleted: true } };
}

async function removeAllOwnedObjects(serviceClient: ServiceClient, userId: string): Promise<boolean> {
    while (true) {
        const { data, error } = await serviceClient.rpc("list_account_owned_storage", { p_user_id: userId });
        if (error || data === null) return false;
        if (data.length === 0) return true;
        const byBucket = Map.groupBy(data, (object) => object.bucket_id);
        for (const [bucket, objects] of byBucket) {
            for (let offset = 0; offset < objects.length; offset += PAGE_SIZE) {
                const { error: removeError } = await serviceClient.storage.from(bucket).remove(objects.slice(offset, offset + PAGE_SIZE).map((object) => object.name));
                if (removeError) return false;
            }
        }
    }
}

function failure(): AccountDeletionResult {
    return { status: 503, body: { code: "account_deletion_failed" } };
}
