begin;
-- Historical zero-byte objects are copied byte-for-byte; new upload APIs still require positive sizes.
alter table media_private.objects drop constraint objects_byte_size_check;
alter table media_private.objects add constraint objects_byte_size_check check (byte_size >= 0);
commit;
