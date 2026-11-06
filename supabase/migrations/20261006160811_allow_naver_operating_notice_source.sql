-- Keep existing Instagram evidence compatible and allow manual Naver notices.
ALTER TABLE public.instagram_posts_raw
  DROP CONSTRAINT IF EXISTS instagram_posts_raw_source_type_check;

ALTER TABLE public.instagram_posts_raw
  ADD CONSTRAINT instagram_posts_raw_source_type_check
  CHECK (source_type IN ('post', 'reel', 'story', 'naver'));
