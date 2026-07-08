#!/usr/bin/env bash

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Program: jamfNotifications.sh
# M.Litton  Nov  1 2023  v1
# B.Mort     7/1/25      v1.1
# B.Mort     6/9/26      v2.0 - cross-platform (macOS bash + Linux runners), Slack OR Teams,
#                               webhook supplied via env/CLI, batched + formatted message
#
# Purpose:
#   Check the notification center on a Jamf Pro server and, if any of the notifications we
#   care about are present, post a single formatted message to Slack or Microsoft Teams.
#
# Runtime:
#   Runs on bash 3.2+ (stock macOS) and bash on Linux GitHub-hosted runners. JSON parsing
#   prefers jq, then python3, then a minimal grep/sed fallback, so no single dependency is
#   required across platforms.
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

set -uo pipefail

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Variables
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Webhook target. Provide via CLI (--webhook / --platform) or environment
# (WEBHOOK_URL / WEBHOOK_PLATFORM). No secrets are hardcoded in this file.
webhookURL="${WEBHOOK_URL:-}"
webhookPlatform="${WEBHOOK_PLATFORM:-slack}"   # slack | teams

# Company brand colors used for the Slack color bar.
BRAND_BLUE="#4A7BA7"
SEV_CRITICAL="#D64541"
SEV_WARNING="#E1B12C"

# The notifications that will trigger a message.
notificationsArr=(
	APNS_CERT_REVOKED
	APNS_CONNECTION_FAILURE
	APPLE_SCHOOL_MANAGER_T_C_NOT_SIGNED
	BUILT_IN_CA_EXPIRED
	BUILT_IN_CA_EXPIRING
	DEP_INSTANCE_EXPIRED
	DEP_INSTANCE_WILL_EXPIRE
	DEVICE_ENROLLMENT_PROGRAM_T_C_NOT_SIGNED
	PUSH_CERT_WILL_EXPIRE
	PUSH_CERT_EXPIRED
	SSO_CERT_WILL_EXPIRE
	SSO_IDP_CERT_WILL_EXPIRE
	VPP_ACCOUNT_EXPIRED
	VPP_ACCOUNT_WILL_EXPIRE
)

scriptResult=""

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Parse our command line arguments
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

while test $# -gt 0; do
	case "$1" in
		--instancesURL)
			shift
			instancesURL="${1%/}"
		;;
		--clientid)
			shift
			client_id="$1"
		;;
		--clientsecret)
			shift
			client_secret="$1"
		;;
		--webhook)
			shift
			webhookURL="$1"
		;;
		--platform)
			shift
			webhookPlatform="$1"
		;;
		*)
			# Exit if we received an unknown option/flag/argument
			[[ "$1" == --* ]] && echo "Unknown option/flag: $1" && exit 4
			[[ "$1" != --* ]] && echo "Unknown argument: $1" && exit 4
		;;
	esac
	shift
done

# Bail if our required options are missing
[[ -z "$instancesURL" ]]   && echo "Error: Missing Jamf Pro URL (--instancesURL); exiting." && exit 1
[[ -z "$client_id" ]]      && echo "Error: Missing Client ID (--clientid); exiting."        && exit 2
[[ -z "$client_secret" ]]  && echo "Error: Missing Client Secret (--clientsecret); exiting." && exit 3
[[ -z "$webhookURL" ]]     && echo "Error: Missing webhook URL (--webhook or WEBHOOK_URL); exiting." && exit 5

# Normalize platform to lowercase (portable; ${var,,} is bash 4+ only).
webhookPlatform=$(printf '%s' "$webhookPlatform" | tr '[:upper:]' '[:lower:]')
if [[ "$webhookPlatform" != "slack" && "$webhookPlatform" != "teams" ]]; then
	echo "Error: --platform must be 'slack' or 'teams' (got '${webhookPlatform}'); exiting."
	exit 6
fi

# Normalize Jamf Pro endpoint:
# - company                      -> https://company.jamfcloud.com
# - company.jamfcloud.com        -> https://company.jamfcloud.com
# - https://company.jamfcloud.com -> unchanged
instancesURL="${instancesURL%/}"
if [[ "${instancesURL}" == http://* || "${instancesURL}" == https://* ]]; then
	:
elif [[ "${instancesURL}" == *.* ]]; then
	instancesURL="https://${instancesURL}"
else
	instancesURL="https://${instancesURL}.jamfcloud.com"
fi

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# JSON helpers (portable: prefer jq, then python3, then grep/sed)
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

JQ="$(command -v jq 2>/dev/null || true)"
PY="$(command -v python3 2>/dev/null || true)"

# Extract the access_token from the OAuth token response on stdin.
extractAccessToken() {
	if [[ -n "$JQ" ]]; then
		"$JQ" -r '.access_token // empty'
	elif [[ -n "$PY" ]]; then
		"$PY" -c 'import sys,json;
try: print(json.load(sys.stdin).get("access_token",""))
except Exception: pass'
	else
		grep -o '"access_token"[[:space:]]*:[[:space:]]*"[^"]*"' \
			| sed 's/.*"access_token"[[:space:]]*:[[:space:]]*"//; s/"$//' \
			| head -n1
	fi
}

# Emit the list of notification "type" values (one per line) from the notifications
# array JSON on stdin.
extractNotificationTypes() {
	if [[ -n "$JQ" ]]; then
		"$JQ" -r '.[].type // empty' 2>/dev/null
	elif [[ -n "$PY" ]]; then
		"$PY" -c 'import sys,json
try:
    d=json.load(sys.stdin)
    for n in d: print(n.get("type",""))
except Exception: pass'
	else
		grep -o '"type"[[:space:]]*:[[:space:]]*"[^"]*"' \
			| sed 's/.*"type"[[:space:]]*:[[:space:]]*"//; s/"$//'
	fi
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Presentation helpers
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Map a raw notification type to a human-readable label.
friendlyLabel() {
	# Keep this list aligned with notificationsArr (the source of truth).
	case "$1" in
		APNS_CERT_REVOKED)                        echo "APNs push certificate revoked" ;;
		APNS_CONNECTION_FAILURE)                  echo "APNs connection failure" ;;
		APPLE_SCHOOL_MANAGER_T_C_NOT_SIGNED)      echo "Apple School Manager terms & conditions not signed" ;;
		BUILT_IN_CA_EXPIRED)                      echo "Built-in CA certificate has expired" ;;
		BUILT_IN_CA_EXPIRING)                     echo "Built-in CA certificate is expiring" ;;
		DEP_INSTANCE_EXPIRED)                     echo "Automated Device Enrollment token has expired" ;;
		DEP_INSTANCE_WILL_EXPIRE)                 echo "Automated Device Enrollment token will expire" ;;
		DEVICE_ENROLLMENT_PROGRAM_T_C_NOT_SIGNED) echo "Apple Business/School Manager terms & conditions not signed" ;;
		PUSH_CERT_WILL_EXPIRE)                    echo "APNs push certificate will expire" ;;
		PUSH_CERT_EXPIRED)                        echo "APNs push certificate has expired" ;;
		SSO_CERT_WILL_EXPIRE)                     echo "SSO certificate will expire" ;;
		SSO_IDP_CERT_WILL_EXPIRE)                 echo "SSO IdP certificate will expire" ;;
		VPP_ACCOUNT_EXPIRED)                      echo "Volume Purchasing (VPP) token has expired" ;;
		VPP_ACCOUNT_WILL_EXPIRE)                  echo "Volume Purchasing (VPP) token will expire" ;;
		*)                                        echo "$1" | tr '_' ' ' ;;
	esac
}

# Severity for a raw notification type: critical | warning | info
severityFor() {
	case "$1" in
		*_EXPIRED|*_NOT_SIGNED|*_REVOKED|*_FAILURE) echo "critical" ;;
		*_WILL_EXPIRE|*_EXPIRING)                   echo "warning" ;;
		*)                                          echo "info" ;;
	esac
}

# Emoji for a severity (unicode renders in both Slack and Teams).
emojiFor() {
	case "$1" in
		critical) echo "🔴" ;;
		warning)  echo "🟡" ;;
		*)        echo "🔵" ;;
	esac
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Jamf Pro API: token lifecycle
# https://developer.jamf.com/jamf-pro/recipes/client-credentials-authorization
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

obtainJamfProAPIBearerToken() {
	response=$(curl --silent --location --request POST "${instancesURL}/api/oauth/token" \
		--header "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "client_id=${client_id}" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_secret=${client_secret}")
	apiBearerToken=$(printf '%s' "$response" | extractAccessToken)
}

validateJamfProAPIBearerToken() {
	apiBearerTokenCheck=$(curl --write-out '%{http_code}' --silent --output /dev/null \
		"${instancesURL}/api/v1/auth" --request GET \
		--header "Authorization: Bearer ${apiBearerToken}")

	scriptResult+="apiBearerTokenCheck: ${apiBearerTokenCheck}; "

	if [[ "${apiBearerTokenCheck}" != 200 ]]; then
		scriptResult+="Error: ${apiBearerTokenCheck}; exiting."
		echo "${scriptResult}"
		exit 1
	fi
}

invalidateJamfProAPIBearerToken() {
	validateJamfProAPIBearerToken

	if [[ "${apiBearerTokenCheck}" == 200 ]]; then
		scriptResult+="Bearer Token still valid; invalidate; "
		curl "${instancesURL}/api/v1/auth/invalidate-token" --silent \
			--header "Authorization: Bearer ${apiBearerToken}" -X POST >/dev/null
		apiBearerToken=""
		scriptResult+="Bearer Token invalidated; "
	else
		scriptResult+="Bearer Token already expired; "
	fi
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Message delivery
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# Send a Slack message using Block Kit with a colored attachment bar.
# $1 = instance, $2 = timestamp, $3 = color, $4 = newline-delimited "emoji label" lines
sendSlack() {
	local instance="$1" timestamp="$2" color="$3" lines="$4"
	local bulletText="" line
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		bulletText+="• ${line}\\n"
	done <<< "$lines"

	local payload
	payload=$(cat <<EOF
{
  "blocks": [
    {
      "type": "header",
      "text": { "type": "plain_text", "text": "🔔 Jamf Pro Notifications", "emoji": true }
    }
  ],
  "attachments": [
    {
      "color": "${color}",
      "blocks": [
        {
          "type": "section",
          "fields": [
            { "type": "mrkdwn", "text": "*Instance:*\\n${instance}" },
            { "type": "mrkdwn", "text": "*Detected:*\\n${timestamp}" }
          ]
        },
        {
          "type": "section",
          "text": { "type": "mrkdwn", "text": "${bulletText}" }
        },
        {
          "type": "context",
          "elements": [ { "type": "mrkdwn", "text": "Sent by BFA Technologies · JamfNotifications" } ]
        }
      ]
    }
  ]
}
EOF
)
	curl --silent --show-error -H "Content-Type: application/json" \
		-d "$payload" "$webhookURL" >/dev/null
}

# Send a Microsoft Teams Adaptive Card to a Power Automate "Workflows" webhook.
# $1 = instance, $2 = timestamp, $3 = brand color hex, $4 = newline-delimited "emoji label" lines
sendTeams() {
	local instance="$1" timestamp="$2" color="$3" lines="$4"
	local bulletText="" line
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# Adaptive Card TextBlock supports limited markdown; bullets via "- ".
		bulletText+="- ${line}\\n\\n"
	done <<< "$lines"

	local payload
	payload=$(cat <<EOF
{
  "type": "message",
  "attachments": [
    {
      "contentType": "application/vnd.microsoft.card.adaptive",
      "content": {
        "\$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": [
          { "type": "TextBlock", "size": "Large", "weight": "Bolder", "color": "Accent", "text": "🔔 Jamf Pro Notifications" },
          {
            "type": "FactSet",
            "facts": [
              { "title": "Instance", "value": "${instance}" },
              { "title": "Detected", "value": "${timestamp}" }
            ]
          },
          { "type": "TextBlock", "wrap": true, "text": "${bulletText}" },
          { "type": "TextBlock", "isSubtle": true, "size": "Small", "spacing": "Medium", "text": "Sent by BFA Technologies · JamfNotifications" }
        ]
      }
    }
  ]
}
EOF
)
	curl --silent --show-error -H "Content-Type: application/json" \
		-d "$payload" "$webhookURL" >/dev/null
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Check notifications and dispatch a single batched message if any are found.
# https://github.com/robjschroeder/Jamf-API-Scripts/blob/main/api-GetJPNotifications.sh
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

checkNotifications() {
	local notificationData
	notificationData=$(curl -s -H "Authorization: Bearer ${apiBearerToken}" \
		-H "Accept: application/json" "${instancesURL}/api/v1/notifications" -X GET)

	# Instance short name, uppercased (e.g. https://bfa.jamfcloud.com -> BFA)
	local JPInstance
	JPInstance=$(printf '%s' "${instancesURL}" | sed 's|^https\{0,1\}://||; s/\..*//' | tr '[:lower:]' '[:upper:]')

	# Distinct notification types currently present on the server.
	local presentTypes
	presentTypes=$(printf '%s' "${notificationData}" | extractNotificationTypes | sort -u)

	# Build the message lines for the notifications we care about.
	local lines="" highest="info" str sev emoji label
	for str in "${notificationsArr[@]}"; do
		if printf '%s\n' "${presentTypes}" | grep -qx "${str}"; then
			sev=$(severityFor "$str")
			emoji=$(emojiFor "$sev")
			label=$(friendlyLabel "$str")
			lines+="${emoji} ${label}"$'\n'

			# Track the highest severity seen for the color bar.
			if [[ "$sev" == "critical" ]]; then
				highest="critical"
			elif [[ "$sev" == "warning" && "$highest" != "critical" ]]; then
				highest="warning"
			fi
		fi
	done

	if [[ -z "$lines" ]]; then
		scriptResult+="No matching notifications for ${JPInstance}; "
		echo "${JPInstance}: no matching notifications."
		return 0
	fi

	# Pick a color bar based on the highest severity present.
	local color="$BRAND_BLUE"
	[[ "$highest" == "warning" ]]  && color="$SEV_WARNING"
	[[ "$highest" == "critical" ]] && color="$SEV_CRITICAL"

	local timestamp
	timestamp=$(date -u "+%Y-%m-%d %H:%M UTC")

	echo "${JPInstance}: sending ${webhookPlatform} notification."
	if [[ "$webhookPlatform" == "teams" ]]; then
		sendTeams "$JPInstance" "$timestamp" "$color" "$lines"
	else
		sendSlack "$JPInstance" "$timestamp" "$color" "$lines"
	fi
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# CODE
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

echo "Getting token for instance: ${instancesURL}"
obtainJamfProAPIBearerToken
validateJamfProAPIBearerToken
checkNotifications
invalidateJamfProAPIBearerToken
