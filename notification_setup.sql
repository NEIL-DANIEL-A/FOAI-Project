-- Phase 7: Push Notification Infrastructure

-- Store FCM tokens per device
create table user_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  fcm_token text not null,
  created_at timestamptz default now()
);
alter table user_devices enable row level security;
create policy "Users can manage own devices" on user_devices
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Students subscribe to routes they care about
create table route_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  route_id uuid references routes(id) on delete cascade,
  created_at timestamptz default now(),
  unique (user_id, route_id)
);
alter table route_subscriptions enable row level security;
create policy "Users can manage own subscriptions" on route_subscriptions
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "Allow public read access to route_subscriptions" on route_subscriptions
  for select using (true);

-- Function: send push notification when trip status changes
create or replace function notify_trip_status_change()
returns trigger as $$
declare
  r record;
  v_route_name text;
  v_bus_number text;
  v_status text;
  v_message text;
begin
  -- Only fire on status change
  if old.running_status is not distinct from new.running_status then
    return new;
  end if;

  v_status := new.running_status;
  if v_status is null then
    return new;
  end if;

  -- Get bus number and route name
  select b.bus_number, r.name into v_bus_number, v_route_name
  from buses b
  join routes r on r.id = new.route_id
  where b.id = new.bus_id;

  -- Build message
  case v_status
    when 'late' then
      v_message := v_bus_number || ' on "' || v_route_name || '" is running late.';
    when 'on_time' then
      v_message := v_bus_number || ' on "' || v_route_name || '" is back on time.';
    when 'arrived' then
      v_message := v_bus_number || ' on "' || v_route_name || '" has arrived at College Gate.';
    else
      return new;
  end case;

  -- Collect FCM tokens of subscribed users
  for r in
    select distinct ud.fcm_token
    from route_subscriptions rs
    join user_devices ud on ud.user_id = rs.user_id
    where rs.route_id = new.route_id
  loop
    perform net.http_post(
      url := current_setting('app.settings.supabase_url') || '/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key')
      ),
      body := jsonb_build_object(
        'token', r.fcm_token,
        'title', 'Bus Update',
        'body', v_message
      )
    );
  end loop;

  return new;
end;
$$ language plpgsql;

create trigger trigger_trip_status_change
after update of running_status on trips
for each row
when (old.running_status is distinct from new.running_status)
execute function notify_trip_status_change();
