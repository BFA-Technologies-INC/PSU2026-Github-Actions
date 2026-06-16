#!/bin/bash
# jamfNotificationsBasic.sh
# Checks a Jamf Pro server for notifications and posts any it finds to Slack.
# Runs on a Linux GitHub runner. All config comes from environment variables.
#
# Required env vars:
#   CLIENT_NAME_BASIC    - friendly name for the tenant (used in the Slack message)
#   JAMF_PRO_URL_BASIC   - Jamf Pro URL (e.g. https://yourorg.jamfcloud.com)
#   CLIENT_ID_BASIC      - API client ID
#   CLIENT_SECRET_BASIC  - API client secret
#   SLACK_WEBHOOK_URL    - Slack incoming webhook URL

set -euo pipefail

# Notifications that should trigger a Slack message
notifications=(
  APPLE_SCHOOL_MANAGER_T_C_NOT_SIGNED
  DEP_INSTANCE_WILL_EXPIRE
  DEVICE_ENROLLMENT_PROGRAM_T_C_NOT_SIGNED
  JAMF_CONNECT_UPDATE
  JAMF_PROTECT_UPDATE
  PUSH_CERT_WILL_EXPIRE
  SSO_CERT_WILL_EXPIRE
  VPP_ACCOUNT_WILL_EXPIRE
  PUSH_CERT_EXPIRED
  DEP_INSTANCE_EXPIRED
)

jamfURL="${JAMF_PRO_URL_BASIC%/}"

# Get a bearer token
token=$(curl -s -X POST "${jamfURL}/api/oauth/token" \
  --data-urlencode "client_id=${CLIENT_ID_BASIC}" \
  --data-urlencode "client_secret=${CLIENT_SECRET_BASIC}" \
  --data-urlencode "grant_type=client_credentials" | jq -r '.access_token')

if [[ -z "${token}" || "${token}" == "null" ]]; then
  echo "Error: could not get a bearer token for ${CLIENT_NAME_BASIC}." && exit 1
fi

# Fetch current notifications
data=$(curl -s -H "Authorization: Bearer ${token}" -H "Accept: application/json" \
  "${jamfURL}/api/v1/notifications")

# Post any matches to Slack
for n in "${notifications[@]}"; do
  if [[ "${data}" == *"${n}"* ]]; then
    message="${CLIENT_NAME_BASIC} Notification: ${n//_/ }"
    echo "${message}"
    curl -s -H "Content-Type: application/json" \
      -d "{\"text\":\"${message}\"}" "${SLACK_WEBHOOK_URL}"
  fi
done

# Invalidate the token
curl -s -X POST -H "Authorization: Bearer ${token}" \
  "${jamfURL}/api/v1/auth/invalidate-token" >/dev/null
