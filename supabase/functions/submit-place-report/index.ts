// Clients keep the original table INSERT route; only its database trigger validates.
Deno.serve(() => Response.json({ code: "endpoint_retired" }, { status: 410 }));
