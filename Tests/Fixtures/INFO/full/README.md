# Full `INFO` replies

Bare `INFO` (default sections) for the Info mode tests (KEEL-042).

- `redis-7.2.txt`: captured from a local Redis 7.2.1 with two keys (db0, db3 with a TTL); host-specific fields
  (`os`, `executable`, `tcp_port`, `run_id`, `process_id`) replaced with neutral values.
- `valkey-8.x.txt`, `dragonfly.txt`: representative replies built from each server's documented field names and
  section layout (Dragonfly adds a `Transaction` section and sends no `rdb_last_save_time`). Replace them with
  captures from the pinned containers when KEEL-048 lands.
