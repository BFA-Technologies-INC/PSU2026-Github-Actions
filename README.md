# Jamf Notifications → Slack (GitHub Actions)

This repo runs Jamf Pro notification checks on a schedule using GitHub Actions
and posts any findings to Slack. It is built for the **Penn State Mac Admins**
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
| **Runner** | `ubuntu-latest` (Linux) |
| **Schedule** | Mondays at 13:00 UTC, plus manual run |

### Setup

In the repo, go to **Settings → Secrets and variables → Actions** and add the
following.

**Variables** (not sensitive — visible in logs is fine):

| Name | Example | Description |
|---|---|---|
| `CLIENT_NAME_BASIC` | `Penn State` | Friendly tenant name used in the Slack message |
| `JAMF_PRO_URL_BASIC` | `https://yourorg.jamfcloud.com` | Your Jamf Pro URL |

**Secrets** (sensitive — masked in logs):

| Name | Description |
|---|---|
| `CLIENT_ID_BASIC` | Jamf Pro API client ID |
| `CLIENT_SECRET_BASIC` | Jamf Pro API client secret |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL |

> **Jamf API credentials:** create an API Role with read access to notifications,
> then an API Client tied to that role. Jamf Pro gives you the client ID and
> secret. See Jamf's [client credentials docs](https://developer.jamf.com/jamf-pro/recipes/client-credentials-authorization).

### Running it

- **Manually:** go to the **Actions** tab → **JamfNotificationsBasic Job** →
  **Run workflow**.
- **On schedule:** it runs automatically every Monday at 13:00 UTC (edit the
  `cron` line in the workflow to change this).

### What it checks

The script posts to Slack if it finds any of these notification types:

- Apple School Manager terms not signed
- DEP / Device Enrollment terms not signed or expiring
- Jamf Connect / Jamf Protect updates available
- Push, SSO, or VPP certificates expiring or expired

Edit the `notifications` array in the script to add or remove types.

---

<!--
## Script: Advanced

(Reserved for the more advanced notifications script. Add its script, workflow,
and required secrets/variables here when it lands.)
-->
