-- Trigger Function: auto-increment trips.current_occupancy on boarding insert
create or replace function handle_boarding_insert()
returns trigger as $$
begin
  update trips
  set current_occupancy = current_occupancy + new.boarding_count
  where id = new.trip_id;
  return new;
end;
$$ language plpgsql;

-- Attach trigger to stop_boardings inserts
create trigger trigger_boarding_insert
after insert on stop_boardings
for each row
execute function handle_boarding_insert();
