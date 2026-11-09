"""임시 PostgreSQL에서 팔로우 신규 배지와 목록별 확인 처리를 검증한다."""

import json
from uuid import UUID

import shutil
import socket
import subprocess
import tempfile
from pathlib import Path


def main():
    for command in ("initdb", "pg_ctl", "psql"):
        if not shutil.which(command):
            raise SystemExit(f"Required local command: {command}")
    migration = Path(__file__).parents[1] / "migrations/20261109073744_follow_connection_read_badges.sql"
    with tempfile.TemporaryDirectory(prefix="ramap-follow-badges-") as directory:
        root = Path(directory)
        database = root / "db"
        subprocess.run(
            ["initdb", "-D", str(database), "--auth=trust", "--no-locale", "--encoding=UTF8"],
            check=True, capture_output=True,
        )
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        subprocess.run(
            ["pg_ctl", "-D", str(database), "-l", str(root / "server.log"),
             "-o", f"-F -p {port} -h 127.0.0.1 -k {directory}", "-w", "start"],
            check=True, capture_output=True,
        )

        def query(sql, denied=False):
            result = subprocess.run(
                ["psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-h", "127.0.0.1",
                 "-p", str(port), "-d", "postgres"],
                input=sql, text=True, capture_output=True,
            )
            if denied:
                assert result.returncode != 0 and ("permission denied" in result.stderr or "row-level security" in result.stderr), result.stderr
            else:
                assert result.returncode == 0, result.stderr
            return result.stdout.strip()

        try:
            query("create role anon; create role authenticated;")
            query("""
                create schema community_private;
                grant usage on schema community_private to authenticated;
                create table public.public_profiles (
                    user_id uuid primary key, nickname text not null,
                    avatar_path text, suspended_at timestamptz
                );
                create table public.account_deletion_requests (user_id uuid primary key);
                create table public.user_blocks (blocker_id uuid, blocked_id uuid);
                create table public.profile_follows (
                    follower_id uuid references public.public_profiles(user_id),
                    followed_id uuid references public.public_profiles(user_id),
                    status text not null check (status in ('pending', 'following')),
                    created_at timestamptz not null default now(),
                    primary key (follower_id, followed_id)
                );
                alter table public.profile_follows enable row level security;
                revoke all on public.profile_follows from public, anon, authenticated;
                create function community_private.require_live_user() returns uuid
                language plpgsql security definer set search_path = '' as $$
                declare current_user_id uuid;
                begin
                    current_user_id := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
                    if current_user_id is null then raise exception 'Login required'; end if;
                    perform 1 from public.public_profiles p where p.user_id = current_user_id for update;
                    return current_user_id;
                end;
                $$;
                revoke all on function community_private.require_live_user() from public, anon, authenticated;
            """)
            query((migration.parent / "20261006040339_follow_management_counts.sql").read_text())
            query("alter function public.fetch_my_follow_counts() volatile;")
            query(migration.read_text())
            users = [str(UUID(int=index)) for index in range(1, 31)]
            owner, other = users[:2]
            for index, user in enumerate(users):
                query(f"insert into public.public_profiles(user_id, nickname) values ('{user}', '사용자{index}');")

            def account(user):
                return f"set role authenticated; set request.jwt.claim.sub = '{user}';"

            def counts(user=owner):
                return json.loads(query(account(user) + "select public.fetch_my_follow_counts();").splitlines()[-1])

            def page(kind, offset=0, user=owner):
                return json.loads(query(account(user) + f"select public.fetch_my_follow_connections('{kind}', {offset});").splitlines()[-1])

            def follow(sender, target=owner, status="following"):
                query(f"insert into public.profile_follows(follower_id, followed_id, status) values ('{sender}', '{target}', '{status}');")

            assert counts() == dict(followers=0, following=0, requests=0,
                                    has_unread_followers=False, has_unread_requests=False)
            for sender in users[2:23]:
                follow(sender)
            follow(users[23], status="pending")
            follow(owner, other)
            follow(users[24], other)
            initial = counts()
            assert initial["followers"] == 21 and initial["requests"] == 1
            assert initial["has_unread_followers"] and initial["has_unread_requests"]
            assert len(page("following")) == 1
            assert counts() == initial, "팔로잉 목록 조회는 받은 팔로우를 확인 처리하지 않는다"
            assert counts(other)["has_unread_followers"], "타인의 팔로워 읽음 상태를 변경하지 않는다"

            assert len(page("followers")) == 20
            assert counts()["has_unread_followers"], "다음 페이지의 새 팔로워는 남아 있어야 한다"
            assert counts()["has_unread_requests"], "다른 목록의 새 신청은 남아 있어야 한다"
            assert len(page("followers", 20)) == 1
            assert not counts()["has_unread_followers"]
            assert counts(other)["has_unread_followers"]
            first_read = query(f"select read_at from public.profile_follows where follower_id = '{users[2]}' and followed_id = '{owner}';")
            page("followers", 20)
            assert query(f"select read_at from public.profile_follows where follower_id = '{users[2]}' and followed_id = '{owner}';") == first_read
            assert len(page("requests")) == 1
            assert counts()["requests"] == 1 and not counts()["has_unread_requests"]
            query(f"update public.profile_follows set status = 'following' where follower_id = '{users[23]}';")
            assert not counts()["has_unread_followers"], "확인한 신청의 승인은 새 팔로워로 재표시하지 않는다"

            query(f"delete from public.profile_follows where follower_id = '{users[2]}' and followed_id = '{owner}';")
            follow(users[25])
            assert counts()["followers"] == 22 and counts()["has_unread_followers"], "수가 같아도 새 관계는 표시한다"
            page("followers")
            query(f"delete from public.profile_follows where follower_id = '{users[25]}' and followed_id = '{owner}';")
            follow(users[25])
            assert counts()["has_unread_followers"], "같은 사용자의 재팔로우도 새 관계다"
            page("followers")

            follow(users[26])
            follow(users[27])
            follow(users[28], status="pending")
            query(f"insert into public.user_blocks values ('{owner}', '{users[26]}');")
            query(f"update public.public_profiles set suspended_at = now() where user_id = '{users[27]}';")
            query(f"insert into public.account_deletion_requests values ('{users[28]}');")
            assert not counts()["has_unread_followers"] and not counts()["has_unread_requests"]
            assert all(row["user_id"] not in users[26:29] for row in page("followers") + page("requests"))
            query("set role anon; select public.fetch_my_follow_counts();", denied=True)
            query("set role anon; select public.fetch_my_follow_connections('followers', 0);", denied=True)
            query(account(owner) + "select * from public.profile_follows;", denied=True)
            query(account(owner) + "update public.profile_follows set read_at = now();", denied=True)
            print("PASS: 새 팔로워·신청, 목록별 확인, 페이지 경계, 계정 격리, 재팔로우, 동일 수 교체, 숨김·권한")
        finally:
            subprocess.run(["pg_ctl", "-D", str(database), "-m", "immediate", "-w", "stop"], check=True, capture_output=True)


if __name__ == "__main__":
    main()
