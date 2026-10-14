# Database query timeout

The SQLite and PostgreSQL images accept `DATABASE_TIMEOUT_MS` as an optional query timeout in milliseconds. Set it in your Compose environment and recreate the container to apply it.

```yaml
environment:
  DATABASE_TIMEOUT_MS: '60000'
```

Values from `15000` through `300000` are accepted, including the endpoints. Surrounding whitespace is trimmed. An unset, blank, malformed, or out-of-range value leaves the defaults unchanged: SQLite uses 45 seconds and PostgreSQL uses Ecto's 15-second default.

This setting controls the database query timeout. It does not change SQLite's busy timeout, the connection pool size, or the application's explicit per-operation timeouts. Raising it can keep connections occupied longer and delay other requests. Start by checking which operation is slow; a larger timeout does not fix storage problems or pool saturation.
