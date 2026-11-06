set local lock_timeout = '5s';
set local statement_timeout = '15s';

CREATE OR REPLACE FUNCTION account_profile_private.fetch_or_create_my_profile(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare profile public.public_profiles;
declare today date := account_profile_private.kst_profile_change_date(current_timestamp);
declare changes account_profile_private.profile_daily_change_counts;
begin
    if auth.uid() is null or p_user_id is distinct from auth.uid() then
        raise exception 'Authentication required or mismatched profile owner' using errcode = '42501';
    end if;
    select * into profile from public.public_profiles where user_id = p_user_id for update;
    if not found then
        begin
            insert into public.public_profiles(user_id, nickname, accepted_at)
            values (p_user_id, (array['설레는','느긋한','행복한','산책하는','든든한','수줍은','춤추는','반가운','호기심많은','여행하는','노래하는','꿈꾸는'])[1 + floor(random() * 12)::int]
                || (array['차슈','아지타마','멘마','돈코츠','쇼유라멘','시오라멘','미소라멘','츠케멘','탄탄멘','라멘한그릇','면발','나루토'])[1 + floor(random() * 12)::int], null)
            on conflict (user_id) do nothing;
        exception when unique_violation then
            -- A generated nickname can collide with a user-selected nickname.
        end;
        select * into profile from public.public_profiles where user_id = p_user_id for update;
    end if;
    while not found loop
        begin
            insert into public.public_profiles(user_id, nickname, accepted_at)
            values (p_user_id, '라멘' || nextval('account_profile_private.generated_nickname_number'::regclass)::text, null)
            on conflict (user_id) do nothing;
        exception when unique_violation then
            -- Advance the fallback sequence when a selected nickname used this value.
        end;
        select * into profile from public.public_profiles where user_id = p_user_id for update;
    end loop;
    select * into changes
    from account_profile_private.profile_daily_change_counts
    where user_id = p_user_id and change_date = today;
    return jsonb_build_object(
        'user_id', profile.user_id,
        'nickname', profile.nickname,
        'avatar_path', profile.avatar_path,
        'bio', profile.bio,
        'is_public', profile.is_public,
        'followers_can_read_reviews', profile.followers_can_read_reviews,
        'followers_can_read_saved_shops', profile.followers_can_read_saved_shops,
        'nickname_changes_remaining', 2 - coalesce(changes.nickname_changes, 0),
        'bio_changes_remaining', 2 - coalesce(changes.bio_changes, 0)
    );
end;
$function$;

CREATE OR REPLACE FUNCTION account_profile_private.guard_profile_identity()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
    if tg_op = 'UPDATE' and (new.nickname is distinct from old.nickname
        or new.avatar_path is distinct from old.avatar_path
        or new.bio is distinct from old.bio) then
        new.approved_at := null;
    end if;
    return new;
end;
$function$;

drop function public.update_my_profile(uuid, text, text, boolean, text, text);
drop function account_profile_private.update_my_profile(uuid, text, text, boolean, text, text);

CREATE OR REPLACE FUNCTION account_profile_private.update_my_profile(p_user_id uuid, p_nickname text, p_avatar_path text DEFAULT NULL::text, p_remove_photo boolean DEFAULT false, p_bio text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare profile public.public_profiles;
declare today date := account_profile_private.kst_profile_change_date(current_timestamp);
declare changes account_profile_private.profile_daily_change_counts;
declare nickname_changed boolean;
declare bio_changed boolean;
begin
    if auth.uid() is null or p_user_id is distinct from auth.uid() then
        raise exception 'Authentication required or mismatched profile owner' using errcode = '42501';
    end if;
    if p_nickname is null or p_nickname !~ '^[A-Za-z0-9가-힣_]{2,10}$'
        or p_remove_photo is null or (p_remove_photo and p_avatar_path is not null) then
        raise exception 'Invalid profile update';
    end if;
    perform account_profile_private.fetch_or_create_my_profile(p_user_id);
    select * into strict profile from public.public_profiles where user_id = p_user_id for update;
    if profile.suspended_at is not null then
        raise exception 'Account is suspended' using errcode = '42501';
    end if;
    if p_avatar_path is not null and (
        p_avatar_path !~ ('^' || p_user_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.](jpg|png)$')
        or not exists (select 1 from storage.objects where bucket_id = 'profile-avatars' and name = p_avatar_path)
    ) then
        raise exception 'Invalid profile avatar';
    end if;

    nickname_changed := p_nickname is distinct from profile.nickname;
    bio_changed := p_bio is not null and p_bio is distinct from profile.bio;
    if nickname_changed or bio_changed then
        insert into account_profile_private.profile_daily_change_counts(user_id, change_date)
        values (p_user_id, today)
        on conflict (user_id, change_date) do nothing;
        select * into strict changes
        from account_profile_private.profile_daily_change_counts
        where user_id = p_user_id and change_date = today
        for update;
        if nickname_changed and changes.nickname_changes >= 2 then
            raise sqlstate 'PT429' using message = 'PROFILE_NICKNAME_DAILY_LIMIT';
        end if;
        if bio_changed and changes.bio_changes >= 2 then
            raise sqlstate 'PT429' using message = 'PROFILE_BIO_DAILY_LIMIT';
        end if;
        update account_profile_private.profile_daily_change_counts
        set nickname_changes = nickname_changes + case when nickname_changed then 1 else 0 end,
            bio_changes = bio_changes + case when bio_changed then 1 else 0 end
        where user_id = p_user_id and change_date = today;
    end if;

    update public.public_profiles
    set nickname = p_nickname,
        bio = coalesce(p_bio, bio),
        avatar_path = case when p_remove_photo then null else coalesce(p_avatar_path, avatar_path) end
    where user_id = p_user_id;
    return account_profile_private.fetch_or_create_my_profile(p_user_id);
end;
$function$;

revoke all on function account_profile_private.update_my_profile(uuid, text, text, boolean, text)
from public, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.update_my_profile(p_user_id uuid, p_nickname text, p_avatar_path text DEFAULT NULL::text, p_remove_photo boolean DEFAULT false, p_bio text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare retry_after integer;
declare failure_message text;
declare failure_state text;
declare failure_constraint text;
declare failure_schema text;
declare failure_table text;
begin
    retry_after := account_profile_private.record_profile_request('profile_save', 5, 30);
    if retry_after > 0 then
        return account_profile_private.profile_request_error('PROFILE_SAVE_RATE_LIMIT', 429, retry_after);
    end if;
    begin
        perform community_private.require_live_user();
        return account_profile_private.update_my_profile(
            p_user_id, p_nickname, p_avatar_path, p_remove_photo, p_bio
        );
    exception when others then
        get stacked diagnostics failure_message = message_text, failure_state = returned_sqlstate,
            failure_constraint = constraint_name, failure_schema = schema_name, failure_table = table_name;
        if failure_state = '23514' and failure_schema = 'public' and failure_table = 'public_profiles'
            and failure_constraint = 'public_profiles_bio_valid' then
            return account_profile_private.profile_request_error('PROFILE_INVALID_BIO', 400);
        end if;
        if failure_state not in ('PT429', '23505', '42501', 'P0001') then
            raise log 'Profile save failed (%): %', failure_state, failure_message;
        end if;
        return account_profile_private.profile_request_error(
            case when failure_state in ('PT429', '42501', 'P0001') then failure_message
                 when failure_state = '23505' then 'PROFILE_NICKNAME_TAKEN'
                 else 'PROFILE_REQUEST_FAILED' end,
            case
                when failure_state = 'PT429' then 429
                when failure_state = '23505' then 409
                when failure_state = '42501' then 403
                when failure_state = 'P0001' then 400
                else 500
            end
        );
    end;
end;
$function$;

revoke all on function public.update_my_profile(uuid, text, text, boolean, text)
from public, anon, authenticated, service_role;
grant execute on function public.update_my_profile(uuid, text, text, boolean, text)
to authenticated, service_role;

alter table public.public_profiles drop column instagram_username;

notify pgrst, 'reload schema';
