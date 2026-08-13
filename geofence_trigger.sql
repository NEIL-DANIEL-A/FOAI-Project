-- Trigger Function running on bus_positions update
create or replace function handle_bus_position_update()
returns trigger as $$
declare
  r_stop record;
  v_route_id uuid;
  v_is_inside boolean;
  v_last_event_type text;
  v_delay_interval interval;
  v_minutes_late double precision;
  v_grace_threshold int := 10; -- default 10 minutes grace period
begin
  -- 1. Get the route_id for this active trip
  select route_id into v_route_id 
  from trips 
  where id = new.trip_id;

  if v_route_id is null then
    return new;
  end if;

  -- 2. Loop through all stops assigned to this route
  for r_stop in 
    select id, name, lat, lon, geofence_radius_m, scheduled_time, sequence_no
    from stops
    where route_id = v_route_id
    order by sequence_no asc
  loop
    -- Check if bus is inside the stop's geofence using PostGIS ST_DWithin
    -- ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography makes geodetic calculations in meters
    v_is_inside := ST_DWithin(
      ST_SetSRID(ST_MakePoint(new.lon, new.lat), 4326)::geography,
      ST_SetSRID(ST_MakePoint(r_stop.lon, r_stop.lat), 4326)::geography,
      r_stop.geofence_radius_m
    );

    -- Find the most recent stop event for this stop and trip
    select event_type into v_last_event_type
    from stop_events
    where trip_id = new.trip_id and stop_id = r_stop.id
    order by actual_time desc
    limit 1;

    if v_is_inside then
      -- Trigger entry event (arrived) if not already marked arrived
      if v_last_event_type is null or v_last_event_type = 'departed' then
        insert into stop_events (trip_id, stop_id, event_type, actual_time)
        values (new.trip_id, r_stop.id, 'arrived', new.updated_at);

        -- Perform arrival delay calculation
        -- Compare current time of day with stops.scheduled_time
        v_delay_interval := (new.updated_at::time) - r_stop.scheduled_time;
        v_minutes_late := extract(epoch from v_delay_interval) / 60.0;

        -- Update running status based on thresholds & stops
        if r_stop.name = 'College Gate' then
          update trips 
          set running_status = 'arrived'
          where id = new.trip_id;
        elsif v_minutes_late > v_grace_threshold then
          update trips 
          set running_status = 'late'
          where id = new.trip_id;
        else
          update trips 
          set running_status = 'on_time'
          where id = new.trip_id;
        end if;
      end if;
    else
      -- Trigger exit event (departed) if currently registered as arrived
      if v_last_event_type = 'arrived' then
        insert into stop_events (trip_id, stop_id, event_type, actual_time)
        values (new.trip_id, r_stop.id, 'departed', new.updated_at);
      end if;
    end if;

  end loop;

  return new;
end;
$$ language plpgsql;

-- Attach trigger to bus_positions updates
create trigger trigger_bus_position_update
after insert or update on bus_positions
for each row
execute function handle_bus_position_update();
