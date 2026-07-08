# Jamf Notifications → Slack / Teams (GitHub Actions)

This repo runs Jamf Pro notification checks using GitHub Actions and posts any
findings to Slack (or Teams). It is built for the **Penn State Mac Admins**
session as an easy, hands-on intro to GitHub Actions.

Each version of the notifications script lives in its own section below, with its
own workflow file, script, and required secrets/variables.

---

## Script: Basic

The simplest version. It checks **one Jamf Pro tenant** for notifications (expiring
certs, unsigned terms, pending updates, etc.) and posts each match to a Slack
channel via an incoming webhook.

| | |
|---|---|
| **Script** | [`jamfNotificationsBasic.sh`](jamfNotificationsBasic.sh) |
| **Workflow** | [`.github/workflows/workflow-basic.yml`](.github/workflows/workflow-basic.yml) |
| **Runner** | `macOS-latest` |
| **Schedule** | Manual run only (`workflow_dispatch`) — the weekly cron is present but commented out in the workflow; uncomment it to re-enable |

### Setup

In the repo, go to **Settings → Secrets and variables → Actions** and add the
following.

**Variables** (not sensitive — visible in logs is fine):

| Name | Example | Description |
|---|---|---|
| `JAMF_PRO_URL_BASIC` | `https://yourorg.jamfcloud.com` | Your Jamf Pro URL |

**Secrets** (sensitive — masked in logs):

| Name | Description |
|---|---|
| `CLIENT_ID_BASIC` | Jamf Pro API client ID |
| `CLIENT_SECRET_BASIC` | Jamf Pro API client secret |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL |

The instance name shown in the Slack message is pulled automatically from
`JAMF_PRO_URL_BASIC` (e.g. `https://bfa.jamfcloud.com` → `BFA`) — there's no
separate "client name" variable to set.

> **Jamf API credentials:** create an API Role with read access to notifications,
> then an API Client tied to that role. Jamf Pro gives you the client ID and
> secret. See Jamf's [client credentials docs](https://developer.jamf.com/jamf-pro/recipes/client-credentials-authorization).

### Running it

- **Manually:** go to the **Actions** tab → **JamfNotificationsBasic Job** →
  **Run workflow**.
- **On schedule:** disabled by default. Uncomment the `cron` line in
  `workflow-basic.yml` to run it automatically (e.g. Mondays at 13:00 UTC).

### What it checks

The script posts one Slack message per match it finds among:

- APNs push certificate revoked / connection failure
- Apple School Manager / Device Enrollment terms not signed
- Built-in CA certificate expired or expiring
- DEP (Automated Device Enrollment) token expired or expiring
- Push certificate expired or expiring
- SSO / SSO IdP certificate expiring
- VPP (Volume Purchasing) token expired or expiring

Edit the `notificationsArr` array in the script to add or remove types.

---

## Script: Advanced

The multi-tenant version. It checks **any number of Jamf Pro tenants** in
parallel (via a matrix strategy), batches all matching notifications for a
tenant into a **single formatted message**, color-codes it by severity, and
can send to **Slack or Microsoft Teams**.

| | |
|---|---|
| **Script** | [`jamfNotificationsAdvanced.sh`](jamfNotificationsAdvanced.sh) |
| **Workflow** | [`.github/workflows/workflow-advanced.yml`](.github/workflows/workflow-advanced.yml) |
| **Runner** | `ubuntu-latest` (Linux); the script also runs unmodified on macOS |
| **Schedule** | Mondays at 13:00 UTC, plus manual run |

### Setup

In the repo, go to **Settings → Secrets and variables → Actions** and add the
following.

**Variables** (not sensitive):

| Name | Example | Description |
|---|---|---|
| `JAMF_TENANTS_JSON` | see below | JSON array describing each tenant to check |
| `CLIENTID_<CLIENT>` | `abc123...` | Jamf Pro API client ID for tenant `<CLIENT>` |
| `WEBHOOK_PLATFORM` | `slack` or `teams` | Optional — defaults to `slack` |

`JAMF_TENANTS_JSON` example (one entry per tenant):

```json
[
  { "name": "Penn State - Main",     "jamfProURL": "https://psu.jamfcloud.com",         "client": "PSU_MAIN" },
  { "name": "Penn State - Altoona",  "jamfProURL": "https://psualtoona.jamfcloud.com",  "client": "PSU_ALTOONA" }
]
```

The `client` field is a label you choose — it's used to look up that tenant's
credentials: variable `CLIENTID_PSU_MAIN` and secret `CLIENTSECRET_PSU_MAIN`.
Add one `CLIENTID_<CLIENT>` variable and one `CLIENTSECRET_<CLIENT>` secret per
tenant in the JSON.

**Secrets** (sensitive):

| Name | Description |
|---|---|
| `CLIENTSECRET_<CLIENT>` | Jamf Pro API client secret for tenant `<CLIENT>` (one per tenant) |
| `WEBHOOK_URL` | Slack incoming webhook URL, or Teams Power Automate workflow URL |

> **Jamf API credentials:** same as Basic — create an API Role with read access
> to notifications, then an API Client tied to that role per tenant. See Jamf's
> [client credentials docs](https://developer.jamf.com/jamf-pro/recipes/client-credentials-authorization).

### Running it

- **Manually:** go to the **Actions** tab → **JamfNotificationsAdvanced Job** →
  **Run workflow**. One job runs per tenant in `JAMF_TENANTS_JSON`.
- **On schedule:** runs automatically every Monday at 13:00 UTC (edit the
  `cron` line in the workflow to change this).
- Tenants missing a `jamfProURL`, client ID, or client secret are skipped with
  a warning rather than failing the whole run.

### What it checks

Same notification types as Basic, plus:

- APNs connection failure
- SSO IdP certificate expiring

Each match is labeled, given a severity (🔴 critical / 🟡 warning / 🔵 info),
and rolled into one message per tenant — colored by the highest severity found.
Edit `notificationsArr` (and `friendlyLabel`/`severityFor` if you want custom
labels or severities) in the script to change what's tracked.
