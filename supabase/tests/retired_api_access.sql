-- Run against a test database after retire_legacy_api_versions.
do $$
declare
    actor text;
    signature text;
begin
    foreach signature in array array[
        'fetch_shop_detail(uuid)',
        'fetch_shop_detail_v2(uuid)',
        'fetch_blocked_community_profiles()',
        'fetch_filtered_review_feed_page(text,text,integer,timestamptz,uuid)',
        'update_my_profile_visibility(boolean)',
        'resolve_media_locations(jsonb)',
        'prepare_media_upload(text,text,text,bigint)',
        'prepare_service_media(text,text,text,bigint)',
        'complete_media_upload(uuid,text,text,text,bigint,text,text)',
        'media_inventory(text,integer)',
        'record_media_copy(text,text,text,text,text,text,bigint,timestamptz)'
    ] loop
        assert to_regprocedure('public.' || signature) is null, signature || ' is still present';
    end loop;

    foreach actor in array array['anon', 'authenticated', 'service_role'] loop
        foreach signature in array array[
            'submit_shop_review(uuid,text,text[],boolean)',
            'update_shop_review(uuid,text,text[],boolean)',
            'delete_shop_review(uuid)',
            'fetch_profile_reviews_page_v2(uuid,bigint)',
            'fetch_profile_reviews_page_v3(uuid,bigint)'
        ] loop
            assert not has_function_privilege(actor, 'public.' || signature, 'execute'),
                actor || ' can call ' || signature;
        end loop;

        assert has_function_privilege(actor, 'public.fetch_shop_detail_v3(uuid)', 'execute');
        assert has_function_privilege(actor, 'public.fetch_profile_reviews_page_v4(uuid,bigint)', 'execute');
        assert has_function_privilege(actor, 'public.resolve_media_locations_v2(jsonb)', 'execute');
        assert has_function_privilege(actor, 'public.submit_shop_review_v2(uuid,text,text[],boolean)', 'execute')
            = (actor <> 'anon');
        assert has_function_privilege(actor, 'public.prepare_service_media_v2(text,text,text,bigint)', 'execute')
            = (actor = 'service_role');
    end loop;
end;
$$;
