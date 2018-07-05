-- Erase DB:
drop schema if exists app_public cascade;
drop schema if exists app_private cascade;

-- Build DB:
create schema app_public;
create schema app_private;

grant usage on schema app_public to graphiledemo_visitor;
alter default privileges in schema app_public grant usage, select on sequences to graphiledemo_visitor;

--------------------------------------------------------------------------------

create function app_private.tg_update_timestamps() returns trigger as $$
begin
  NEW.created_at = (case when TG_OP = 'INSERT' then NOW() else OLD.created_at end);
  NEW.updated_at = (case when TG_OP = 'UPDATE' and OLD.updated_at <= NOW() then OLD.updated_at + interval '1 millisecond' else NOW() end);
	return NEW;
end;
$$ language plpgsql volatile set search_path from current;

comment on function app_private.tg_update_timestamps() is E'This trigger should be called on all tables with created_at, updated_at - it ensures that created_at cannot be manipulated and that updated_at is strictly increasing.';

--------------------------------------------------------------------------------

create function app_public.current_user_id() returns int as $$
  select nullif(current_setting('jwt.claims.user_id', true), '')::int;
$$ language sql stable set search_path from current;
comment on function  app_public.current_user_id() is E'@omit\nHandy method to get the current user ID for use in RLS policies, etc; in GraphQL should use `currentUser{id}` instead.';

--------------------------------------------------------------------------------

create table app_public.users (
  id serial primary key,
  username citext not null,
  name text,
  avatar_url text check(avatar_url ~ '^https?://[^/]+'),
	is_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table app_public.users enable row level security;
create trigger _100_timestamps after insert or update on app_public.users for each row execute procedure app_private.tg_update_timestamps();

comment on table app_public.users is E'@omit create,all\nA user who can log in to the application.';
comment on column app_public.users.id is E'@omit update';
comment on column app_public.users.name is E'Public-facing name (or pseudonym) of the user.';
comment on column app_public.users.avatar_url is E'Optional avatar URL.';
comment on column app_public.users.is_admin is E'@omit create,update';
comment on column app_public.users.created_at is E'@omit create,update';
comment on column app_public.users.updated_at is E'@omit create,update';

create policy select_all on app_public.users for select using (true);
create policy update_self on app_public.users for update using (id = app_public.current_user_id());
create policy delete_self on app_public.users for delete using (id = app_public.current_user_id());
grant select on app_public.users to graphiledemo_visitor;
grant update(name, avatar_url) on app_public.users to graphiledemo_visitor;
grant delete on app_public.users to graphiledemo_visitor;

create function app_private.tg_users__make_first_user_admin() returns trigger as $$
begin
  if not exists(select 1 from app_public.users) then
    NEW.is_admin = true;
  end if;
  return NEW;
end;
$$ language plpgsql volatile;
create trigger _200_make_first_user_admin before insert on app_public.users for each row execute procedure app_private.tg_users__make_first_user_admin();

--------------------------------------------------------------------------------

create function app_public.current_user_is_admin() returns bool as $$
  -- We're using exists here because it guarantees true/false rather than true/false/null
  select exists(
    select 1 from app_public.users where id = app_public.current_user_id() and is_admin = true
	);
$$ language sql stable set search_path from current;
comment on function  app_public.current_user_is_admin() is E'@omit\nHandy method to determine if the current user is an admin, for use in RLS policies, etc; in GraphQL should use `currentUser{isAdmin}` instead.';

--------------------------------------------------------------------------------

create function app_public.current_user() returns app_public.users as $$
  select users.* from app_public.users where id = app_public.current_user_id();
$$ language sql stable set search_path from current;

--------------------------------------------------------------------------------

create table app_private.user_secrets (
  user_id int not null primary key references app_public.users,
  password_hash text,
  password_attempts int not null default 0,
  first_failed_password_attempt timestamptz,
  reset_password_token text,
  reset_password_token_generated timestamptz,
  reset_password_attempts int not null default 0,
  first_failed_reset_password_attempt timestamptz
);

create function app_private.tg_user_secrets__insert_with_user() returns trigger as $$
begin
  insert into app_private.user_secrets(user_id) values(NEW.id);
  return NEW;
end;
$$ language plpgsql volatile;
create trigger _500_insert_secrets after insert on app_public.users for each row execute procedure app_private.tg_user_secrets__insert_with_user();

--------------------------------------------------------------------------------

create table app_public.user_emails (
  id serial primary key,
  user_id int not null default app_public.current_user_id() references app_public.users on delete cascade,
  email citext not null CHECK (email ~ '[^@]+@[^@]+\.[^@]+'),
  is_verified boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, email)
);
create unique index uniq_user_emails_verified_email on app_public.user_emails(email) where is_verified is true;
alter table app_public.user_emails enable row level security;
create trigger _100_timestamps after insert or update on app_public.user_emails for each row execute procedure app_private.tg_update_timestamps();
comment on table app_public.user_emails is E'@omit update,all\nInformation about a user''s email address.';
comment on column app_public.user_emails.user_id is E'@omit';
comment on column app_public.user_emails.email is E'The users email address, in `a@b.c` format.';
comment on column app_public.user_emails.is_verified is E'True if the user has is_verified their email address (by clicking the link in the email we sent them, or logging in with a social login provider), false otherwise.';
comment on column app_public.user_emails.created_at is E'@omit create,update';
comment on column app_public.user_emails.updated_at is E'@omit create,update';

create policy select_own on app_public.user_emails for select using (user_id = app_public.current_user_id());
create policy insert_own on app_public.user_emails for insert with check (user_id = app_public.current_user_id());
create policy delete_own on app_public.user_emails for delete using (user_id = app_public.current_user_id()); -- TODO check this isn't the last one!
grant select on app_public.user_emails to graphiledemo_visitor;
grant insert (email) on app_public.user_emails to graphiledemo_visitor;
grant delete on app_public.user_emails to graphiledemo_visitor;

--------------------------------------------------------------------------------

create table app_private.user_email_secrets (
  user_email_id int primary key references app_public.user_emails on delete cascade,
  verification_token text,
  password_reset_email_sent_at timestamptz
);
alter table app_private.user_email_secrets enable row level security;

--------------------------------------------------------------------------------

create table app_public.user_authentications (
  id serial primary key,
  user_id int not null references app_public.users on delete cascade,
  service text not null,
  identifier text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uniq_user_authentications unique(service, identifier)
);
alter table app_public.user_authentications enable row level security;
create trigger _100_timestamps after insert or update on app_public.user_authentications for each row execute procedure app_private.tg_update_timestamps();

comment on table app_public.user_authentications is E'@omit create,update,all\nContains information about the login providers this user has used, so that they may disconnect them should they wish.';
comment on column app_public.user_authentications.user_id is E'@omit';
comment on column app_public.user_authentications.service is E'The login service used, e.g. `twitter` or `github`.';
comment on column app_public.user_authentications.identifier is E'A unique identifier for the user within the login service.';
comment on column app_public.user_authentications.details is E'@omit\nAdditional profile details extracted from this login method';
comment on column app_public.user_authentications.created_at is E'@omit create,update';
comment on column app_public.user_authentications.updated_at is E'@omit create,update';

create policy select_own on app_public.user_authentications for select using (user_id = app_public.current_user_id());
create policy delete_own on app_public.user_authentications for delete using (user_id = app_public.current_user_id()); -- TODO check this isn't the last one!
grant select on app_public.user_authentications to graphiledemo_visitor;
grant delete on app_public.user_authentications to graphiledemo_visitor;

--------------------------------------------------------------------------------

create table app_private.user_authentication_secrets (
  user_authentication_id int not null primary key references app_public.user_authentications on delete cascade,
  details jsonb not null default '{}'::jsonb
);
alter table app_private.user_authentication_secrets enable row level security;

--------------------------------------------------------------------------------

create function app_public.forgot_password(email text) returns boolean as $$
declare
  v_user_email app_public.user_emails;
  v_reset_token text;
  v_reset_min_duration_between_emails interval = interval '30 minutes';
  v_reset_max_duration interval = interval '3 days';
begin
  -- Find the matching user_email
  select user_emails.* into v_user_email
  from app_public.user_emails
  where user_emails.email = forgot_password.email::citext
  order by is_verified desc, id desc;

  if not (v_user_email is null) then
    -- See if we've triggered a reset recently
    if exists(
      select 1
      from app_private.user_email_secrets
      where user_email_id = v_user_email.id
      and password_reset_email_sent_at is not null
      and password_reset_email_sent_at > now() - v_reset_min_duration_between_emails
    ) then
      return true;
    end if;

    -- Fetch or generate reset token
    update app_private.user_secrets
    set
      reset_password_token = (
        case
        when reset_password_token is null or reset_password_token_generated < NOW() - v_reset_max_duration
        then encode(gen_random_bytes(6), 'hex')
        else reset_password_token
        end
      ),
      reset_password_token_generated = (
        case
        when reset_password_token is null or reset_password_token_generated < NOW() - v_reset_max_duration
        then now()
        else reset_password_token_generated
        end
      )
    where user_id = v_user_email.user_id
    returning reset_password_token into v_reset_token;

    -- Don't allow spamming an email
    update app_private.user_email_secrets
    set password_reset_email_sent_at = now()
    where user_email_id = v_user_email.id;

    -- Trigger email send
    perform app_jobs.add_job('user__forgot_password', json_build_object('id', v_user_email.user_id, 'email', v_user_email.email::text, 'token', v_reset_token));
    return true;

  end if;
  return false;
end;
$$ language plpgsql security definer volatile;

--------------------------------------------------------------------------------

create function app_private.login(username text, password text) returns app_public.users as $$
declare
  v_user app_public.users;
  v_user_secret app_private.user_secrets;
  v_login_attempt_window_duration interval = interval '6 hours';
begin
  select users.* into v_user
  from app_public.users
  where
    -- Match username against users username, or any verified email address
    (
      users.username = login.username
    or
      exists(
        select 1
        from app_public.user_emails
        where user_id = users.id
        and is_verified is true
        and email = login.username::citext
      )
    );

  if not (v_user is null) then
    -- Load their secrets
    select * into v_user_secret from app_private.user_secrets
    where user_secrets.user_id = v_user.id;

    -- Have there been too many login attempts?
    if (
      v_user_secret.first_failed_password_attempt is not null
    and
      v_user_secret.first_failed_password_attempt > NOW() - v_login_attempt_window_duration
    and
      v_user_secret.password_attempts >= 20
    ) then
      raise exception 'User account locked - too many login attempts' using errcode = 'LOCKD';
    end if;

    -- Not too many login attempts, let's check the password
    if v_user_secret.password_hash = crypt(password, v_user_secret.password_hash) then
      -- Excellent - they're loggged in! Let's reset the attempt tracking
      update app_private.user_secrets
      set password_attempts = 0, first_failed_password_attempt = null
      where user_id = v_user.id;
      return v_user;
    else
      -- Wrong password, bump all the attempt tracking figures
      update app_private.user_secrets
      set
        password_attempts = (case when first_failed_password_attempt is null or first_failed_password_attempt < now() - v_login_attempt_window_duration then 1 else password_attempts + 1 end),
        first_failed_password_attempt = (case when first_failed_password_attempt is null or first_failed_password_attempt < now() - v_login_attempt_window_duration then now() else first_failed_password_attempt end)
      where user_id = v_user.id;
      return null;
    end if;
  else
    -- No user with that email/username was found
    return null;
  end if;
end;
$$ language plpgsql security definer volatile;

--------------------------------------------------------------------------------

create function app_public.reset_password(user_id int, reset_token text, new_password text) returns app_public.users as $$
declare
  v_user app_public.users;
  v_user_secret app_private.user_secrets;
  v_reset_max_duration interval = interval '3 days';
begin
  select users.* into v_user
  from app_public.users
  where id = user_id;

  if not (v_user is null) then
    -- Load their secrets
    select * into v_user_secret from app_private.user_secrets
    where user_secrets.user_id = v_user.id;

    -- Have there been too many reset attempts?
    if (
      v_user_secret.first_failed_reset_password_attempt is not null
    and
      v_user_secret.first_failed_reset_password_attempt > NOW() - v_reset_max_duration
    and
      v_user_secret.reset_password_attempts >= 20
    ) then
      raise exception 'Password reset locked - too many reset attempts' using errcode = 'LOCKD';
    end if;

    -- Not too many reset attempts, let's check the token
    if v_user_secret.reset_password_token = reset_token then
      -- Excellent - they're legit; let's reset the password as requested
      update app_private.user_secrets
      set
        password_hash = crypt(new_password, gen_salt('bf')),
        password_attempts = 0,
        first_failed_password_attempt = null,
        reset_password_token = null,
        reset_password_token_generated = null,
        reset_password_attempts = 0,
        first_failed_reset_password_attempt = null
      where user_secrets.user_id = v_user.id;
      return v_user;
    else
      -- Wrong token, bump all the attempt tracking figures
      update app_private.user_secrets
      set
        reset_password_attempts = (case when first_failed_reset_password_attempt is null or first_failed_reset_password_attempt < now() - v_reset_max_duration then 1 else reset_password_attempts + 1 end),
        first_failed_reset_password_attempt = (case when first_failed_reset_password_attempt is null or first_failed_reset_password_attempt < now() - v_reset_max_duration then now() else first_failed_reset_password_attempt end)
      where user_secrets.user_id = v_user.id;
      return null;
    end if;
  else
    -- No user with that id was found
    return null;
  end if;
end;
$$ language plpgsql volatile security definer;

--------------------------------------------------------------------------------

create function app_private.register_user(f_service character varying, f_identifier character varying, f_profile json, f_auth_details json, f_email_is_verified boolean default false) returns app_public.users as $$
declare
  v_user app_public.users;
  v_email citext;
  v_name text;
  v_username text;
  v_avatar_url text;
  v_user_authentication_id int;
begin
  -- Insert the user’s public profile data.
  v_email := f_profile ->> 'email';
  v_name := f_profile ->> 'name';
  v_username := f_profile ->> 'username';
  v_avatar_url := f_profile ->> 'avatar_url';
  if v_username is null then
    v_username = coalesce(v_name, 'user');
  end if;
  v_username = regexp_replace(v_username, '^[^a-z]+', '', 'i');
  v_username = regexp_replace(v_username, '[^a-z0-9]+', '_', 'i');
  if v_username is null or length(v_username) < 3 then
    v_username = 'user';
  end if;
  select (
    case
    when i = 0 then v_username
    else v_username || i::text
    end
  ) into v_username from generate_series(0, 1000) i
  where not exists(
    select 1
    from app_public.users
    where username = (
      case
      when i = 0 then v_username
      else v_username || i::text
      end
    )
  )
  limit 1;
  insert into app_public.users (username, name, avatar_url) values
    (v_username, v_name, v_avatar_url)
    returning * into v_user;

	-- Add the users email
  if v_email is not null then
    insert into app_public.user_emails (user_id, email, is_verified)
    values (v_user.id, v_email, f_verified);
  end if;

  -- Insert the user’s private account data (e.g. OAuth tokens)
  insert into app_public.user_authentications (user_id, service, identifier, details) values
    (v_user.id, f_service, f_identifier, f_profile) returning id into v_user_authentication_id;
  insert into app_private.user_authentication_secrets (user_authentication_id, details) values
    (v_user_authentication_id, f_auth_details);

  return v_user;
end;
$$ language plpgsql set search_path from current;

--------------------------------------------------------------------------------

create function app_private.link_or_register_user(
  f_user_id integer,
  f_service character varying,
  f_identifier character varying,
  f_profile json,
  f_auth_details json
) RETURNS app_public.users
 LANGUAGE plpgsql
    SET search_path from current
    AS $$
declare
  v_matched_user_id int;
  v_matched_authentication_id int;
  v_email citext;
  v_name text;
  v_avatar_url text;
  v_user app_public.users;
  v_user_email app_public.user_emails;
begin
  select id, user_id
    into v_matched_authentication_id, v_matched_user_id
    from app_public.user_authentications
    where service = f_service
    and identifier = f_identifier
    and (f_user_id is null or user_id = f_user_id)
    limit 1;

  v_email = f_profile ->> 'email';
  v_name := f_profile ->> 'name';
  v_avatar_url := f_profile ->> 'avatar_url';

  if v_matched_authentication_id is null then
    if f_user_id is not null then
      -- Link new account to logged in user account
      insert into app_public.user_authentications (user_id, service, identifier, details) values
        (f_user_id, f_service, f_identifier, f_profile) returning id, user_id into v_matched_authentication_id, v_matched_user_id;
      insert into app_private.user_authentication_secrets (user_authentication_id, details) values
        (v_matched_authentication_id, f_auth_details);
    elsif v_email is not null then
      -- See if the email is registered
      select * into v_user_email from app_public.user_emails where email = v_email and is_verified is true;
      if v_user_email is not null then
        -- User exists!
        insert into app_public.user_authentications (user_id, service, identifier, details) values
          (v_user_email.user_id, f_service, f_identifier, f_profile) returning id, user_id into v_matched_authentication_id, v_matched_user_id;
        insert into app_private.user_authentication_secrets (user_authentication_id, details) values
          (v_matched_authentication_id, f_auth_details);
      end if;
    end if;
  end if;
  if v_matched_user_id is null and f_user_id is null and v_matched_authentication_id is null then
    return app_private.register_user(f_service, f_identifier, f_profile, f_auth_details, true);
  else
    if v_matched_authentication_id is not null then
      update app_public.user_authentications
        set details = f_profile
        where id = v_matched_authentication_id;
      update app_private.user_authentication_secrets
        set details = f_auth_details
        where user_authentication_id = v_matched_authentication_id;
      update app_public.users
        set
          name = coalesce(users.name, v_name),
          avatar_url = coalesce(users.avatar_url, v_avatar_url)
        where id = v_matched_user_id
        returning  * into v_user;
      return v_user;
    else
      -- v_matched_authentication_id is null
      -- -> v_matched_user_id is null (they're paired)
      -- -> f_user_id is not null (because the if clause above)
      -- -> v_matched_authentication_id is not null (because of the separate if block above creating a user_authentications)
      -- -> contradiction.
      raise exception 'This should not occur';
    end if;
  end if;
end;
$$;

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--                                                                            --
--                    END OF COMMON APPLICATION SETUP                         --
--                                                                            --
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

-- Forum example

create table app_public.forums (
  id serial primary key,
  slug text not null check(length(slug) < 30 and slug ~ '^([a-z0-9]-?)+$'),
  name text not null check(length(name) > 0),
	description text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table app_public.forums enable row level security;
create trigger _100_timestamps after insert or update on app_public.forums for each row execute procedure app_private.tg_update_timestamps();

comment on table app_public.forums is E'A subject-based grouping of topics and posts.';
comment on column app_public.forums.id is E'@omit create,update';
comment on column app_public.forums.slug is E'An URL-safe alias for the `Forum`.';
comment on column app_public.forums.name is E'The name of the `Forum` (indicates its subject matter).';
comment on column app_public.forums.description is E'A brief description of the `Forum` including it''s purpose.';
comment on column app_public.forums.created_at is E'@omit create,update';
comment on column app_public.forums.updated_at is E'@omit create,update';

create policy select_all on app_public.forums for select using (true);
create policy insert_admin on app_public.forums for insert with check (app_public.current_user_is_admin());
create policy update_admin on app_public.forums for update using (app_public.current_user_is_admin());
create policy delete_admin on app_public.forums for delete using (app_public.current_user_is_admin());
grant select on app_public.forums to graphiledemo_visitor;
grant insert(slug, name, description) on app_public.forums to graphiledemo_visitor;
grant update(slug, name, description) on app_public.forums to graphiledemo_visitor;
grant delete on app_public.forums to graphiledemo_visitor;

--------------------------------------------------------------------------------

create table app_public.topics (
  id serial primary key,
  forum_id int not null references app_public.forums on delete cascade,
  user_id int not null default app_public.current_user_id() references app_public.users on delete cascade,
  title text not null check(length(title) > 0),
	body text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table app_public.topics enable row level security;
create trigger _100_timestamps after insert or update on app_public.topics for each row execute procedure app_private.tg_update_timestamps();

comment on table app_public.topics is E'@omit all\nAn individual message thread within a Forum.';
comment on column app_public.topics.id is E'@omit create,update';
comment on column app_public.topics.forum_id is E'@omit update';
comment on column app_public.topics.user_id is E'@omit create,update';
comment on column app_public.topics.title is E'The title of the `Topic`.';
comment on column app_public.topics.body is E'The body of the `Topic`, which Posts reply to.';
comment on column app_public.topics.created_at is E'@omit create,update';
comment on column app_public.topics.updated_at is E'@omit create,update';

create policy select_all on app_public.topics for select using (true);
create policy insert_admin on app_public.topics for insert with check (user_id = app_public.current_user_id());
create policy update_admin on app_public.topics for update using (user_id = app_public.current_user_id() or app_public.current_user_is_admin());
create policy delete_admin on app_public.topics for delete using (user_id = app_public.current_user_id() or app_public.current_user_is_admin());
grant select on app_public.topics to graphiledemo_visitor;
grant insert(forum_id, title, body) on app_public.topics to graphiledemo_visitor;
grant update(title, body) on app_public.topics to graphiledemo_visitor;
grant delete on app_public.topics to graphiledemo_visitor;

--------------------------------------------------------------------------------

create table app_public.posts (
  id serial primary key,
  topic_id int not null references app_public.topics on delete cascade,
  user_id int not null default app_public.current_user_id() references app_public.users on delete cascade,
	body text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table app_public.posts enable row level security;
create trigger _100_timestamps after insert or update on app_public.posts for each row execute procedure app_private.tg_update_timestamps();

comment on table app_public.posts is E'@omit all\nAn individual message thread within a Forum.';
comment on column app_public.posts.id is E'@omit create,update';
comment on column app_public.posts.topic_id is E'@omit update';
comment on column app_public.posts.user_id is E'@omit create,update';
comment on column app_public.posts.body is E'The body of the `Topic`, which Posts reply to.';
comment on column app_public.posts.created_at is E'@omit create,update';
comment on column app_public.posts.updated_at is E'@omit create,update';

create policy select_all on app_public.posts for select using (true);
create policy insert_admin on app_public.posts for insert with check (user_id = app_public.current_user_id());
create policy update_admin on app_public.posts for update using (user_id = app_public.current_user_id() or app_public.current_user_is_admin());
create policy delete_admin on app_public.posts for delete using (user_id = app_public.current_user_id() or app_public.current_user_is_admin());
grant select on app_public.posts to graphiledemo_visitor;
grant insert(topic_id, body) on app_public.posts to graphiledemo_visitor;
grant update(body) on app_public.posts to graphiledemo_visitor;
grant delete on app_public.posts to graphiledemo_visitor;
