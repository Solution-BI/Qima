# Alerts

## Overview

The alerts group sends an email whenever a Dagster run fails, so failures are noticed without
watching the Dagster UI. It wraps Dagster's built-in `make_email_on_run_failure_sensor` and is
intentionally minimal: a single run-failure sensor that emails one static recipient list.

The sensor is active in **every environment** whenever email is configured — only the recipients
differ. Set `ALERT_EMAIL_TO` to your own address in dev and to the team list in prod (via each
deployment's `.env`). Leave the email config blank to disable alerting entirely. Because run
failures include failures caused by blocking asset checks, check-induced failures are also alerted.

- Source: `src/data_import/defs/alerts/sensors.py`
- Wiring: registered in `data_import.definitions` independently of the Snowflake config load, so
  alerting still works if dynamic (Snowflake-driven) definitions fail to load.

## Operations

`make_alert_sensor_l(settings)` returns the deployment's alert sensors — a one-element list in prod
with complete config, otherwise empty. `definitions.py` merges these into the `Definitions` object.

`make_email_failure_sensor(settings)` returns the sensor or `None`:

1. Returns `None` (and logs) when email alerting is not configured (`settings.alerting_enabled` is
   false — i.e. no SMTP config / recipients).
2. Otherwise builds a `dagster.make_email_on_run_failure_sensor` with `default_status=RUNNING`,
   monitoring all jobs in the code location. The subject line is tagged with the environment
   (`[data-import][dev|prod] Job failed: <job>`).

`Settings` validates the email config as all-or-nothing at startup (`check_alerting_config`): a
partial or typo'd config fails fast, while a fully empty config simply disables alerting.

### Configuration

All email config is read from environment variables via `Settings` (see `.env.example`). All values
must be set together to enable alerting, in any environment:

| Env var          | Maps to                              | Notes                                       |
| ---------------- | ------------------------------------ | ------------------------------------------- |
| `SMTP_HOST`      | `smtp_host`                          | SMTP server hostname                        |
| `SMTP_PORT`      | `smtp_port`                          | `465` for SSL, `587` for STARTTLS           |
| `SMTP_TYPE`      | `smtp_type`                          | `SSL` (default) or `STARTTLS`               |
| `SMTP_USER`      | `smtp_user`                          | SMTP auth username (usually the address)    |
| `SMTP_PASSWORD`  | `email_password`                     | SMTP auth password / app password           |
| `SMTP_SENDER`    | `email_from`                         | From address                                |
| `ALERT_EMAIL_TO` | `email_to` (via `alert_recipients`)  | Comma-separated; your address in dev,       |
|                  |                                      | the team list in prod                       |

## Functions

### make_email_failure_sensor

- Input: `settings: data_import.config.settings.Settings`
- Output: `dagster.SensorDefinition | None`

### make_alert_sensor_l

- Input: `settings: data_import.config.settings.Settings`
- Output: `list[dagster.SensorDefinition]`
