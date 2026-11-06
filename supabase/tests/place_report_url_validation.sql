-- Read-only URL validation cases; no report, quota or notification is created.
with cases(value, expected) as (
    values
        ('https://naver.me/FmGMf5P4', true),
        ('https://naver.me/FmGMf5P4?share=true', true),
        ('https://kko.to/i2sQooNyPb', true),
        ('https://map.naver.com/p/entry/place/123', true),
        ('https://map.naver.com/v5/entry/place/123?c=15', true),
        ('https://map.naver.com?app=Y&pinType=site&pinId=123&version=2', true),
        ('https://map.naver.com/p?pinId=123&title=ramen', true),
        ('https://m.place.naver.com/restaurant/123/home', true),
        ('https://place.map.kakao.com/123?referrer=share', true),
        ('https://map.kakao.com/link/map/123', true),
        ('https://applink.map.kakao.com/?id=123', true),
        ('https://applink.map.kakao.com/place?id=123&t_src=share', true),
        ('https://naver.me/test', false),
        ('https://naver.me/', false),
        ('https://naver.me/FmGMf5P4/extra', false),
        ('https://kko.to/test', false),
        ('https://map.naver.com/p?title=unknown', false),
        ('https://map.naver.com/p?x=pinId=123', false),
        ('https://place.map.kakao.com/test', false),
        ('https://place.map.kakao.com/0', false),
        ('https://example.com/place', false),
        ('https://blog.naver.com/123', false),
        ('https://naver.me:443/FmGMf5P4', false),
        ('https://naver.me@evil.example/FmGMf5P4', false),
        ('https://naver.me.evil.example/FmGMf5P4', false),
        ('https://naver.me/FmGMf5P4#fragment', false),
        ('http://naver.me/FmGMf5P4', false)
), results as (
    select value, expected,
        report_submission_private.is_valid_place_report_url(value) as actual
    from cases
)
select count(*) as cases,
    count(*) filter (where actual is not distinct from expected) as passed,
    coalesce(jsonb_agg(value) filter (where actual is distinct from expected), '[]'::jsonb) as failures
from results;
