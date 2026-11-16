#!/usr/bin/env bash
# Problem 4 lab, part B: what a rollback does - and does not do - after a DB migration (line 77:
# "Do not assume redeploying an old image restores the database").
# The "app" is one SQL statement per version: v1 uses column "comment", v2 uses column "feedback".
# Runs on master; psql runs inside the pg-prod pod (recovery-lab), in its own database release_demo.
# Usage: bash scripts/local-test/migration-lab.sh <step>
set -euo pipefail

# Run SQL from stdin in the release_demo database. ON_ERROR_STOP=1: stop at the first SQL error.
sql() { kubectl -n recovery-lab exec -i pg-prod -c postgres -- psql -U postgres -d release_demo -v ON_ERROR_STOP=1; }

case "${1:-}" in
  setup)
    # Release 1: a fresh database with column "comment" and 3 rows.
    kubectl -n recovery-lab exec pg-prod -c postgres -- psql -U postgres \
      -c "drop database if exists release_demo" -c "create database release_demo"
    sql <<'SQL'
create table responses (id serial primary key, comment text);
insert into responses (comment) values ('good'), ('ok'), ('bad');
SQL
    ;;
  app-v1)
    # App v1: writes and reads "comment".
    sql <<'SQL'
insert into responses (comment) values ('written by v1');
select id, comment from responses order by id;
SQL
    ;;
  app-v2)
    # App v2: writes and reads "feedback".
    sql <<'SQL'
insert into responses (feedback) values ('written by v2');
select id, feedback from responses order by id;
SQL
    ;;
  migrate-rename)
    # Release 2 migration, INCOMPATIBLE with v1: the old column name disappears.
    sql <<'SQL'
alter table responses rename column comment to feedback;
SQL
    ;;
  undo-rename)
    # Down-migration (written and tested in advance): back to the old name, no data lost.
    sql <<'SQL'
alter table responses rename column feedback to comment;
SQL
    ;;
  expand)
    # Release 2 migration, COMPATIBLE (expand): add the new column, keep the old one, copy the data,
    # and a trigger fills whichever column an insert left empty, so v1 and v2 can run side by side.
    sql <<'SQL'
alter table responses add column feedback text;
update responses set feedback = comment;
create function sync_feedback() returns trigger language plpgsql as $$
begin
  if new.feedback is null then new.feedback := new.comment; end if;
  if new.comment is null then new.comment := new.feedback; end if;
  return new;
end $$;
create trigger sync_feedback before insert on responses
  for each row execute function sync_feedback();
SQL
    ;;
  contract)
    # Release 3 (contract): only after no v1 runs any more - remove the trigger and the old column.
    sql <<'SQL'
drop trigger sync_feedback on responses;
drop function sync_feedback();
alter table responses drop column comment;
SQL
    ;;
  *)
    echo "usage: $0 setup|app-v1|app-v2|migrate-rename|undo-rename|expand|contract" >&2
    exit 1
    ;;
esac
