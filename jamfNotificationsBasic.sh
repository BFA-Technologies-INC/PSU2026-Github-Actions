#!/bin/bash

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Program: jamfNotificationsBasic-Local.sh
# BFA Technologies on 2 June 2026
#
# Purpose:
# Check for any specified notification that may be present on a Jamf Pro Server
# List of available notifications can be found at
# https://developer.jamf.com/jamf-pro/reference/delete_v1-notifications-type-id
#
# Inspired by:
# robjschroeder - api-GetJPNotifications.sh
# https://github.com/robjschroeder/Jamf-API-Scripts/blob/main/api-GetJPNotifications.sh
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# VARIABLES
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

JAMF_PRO_URL_BASIC="https://bfatechnolbrianjxitq.jamfcloud.com"
CLIENT_ID_BASIC="c316ce55-9624-4ef9-ac8c-eb4c42814834"   
CLIENT_SECRET_BASIC="EhSpepfhJkhWoUVAgDVmwA3VXoWOfG-COxFVwsVdO1UMZc0aN6aEKKyShXoNkrDW"
slackWebhookURL="https://hooks.slack.com/services/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"

# Notifications that should trigger a Slack message
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

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# FUNCTIONS
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Get Access Token
# This function uses the supplied variables to generate an access token that is stored in the $access_token variable
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

getAccessToken() {
	response=$(curl --silent --location --request POST "${JAMF_PRO_URL_BASIC}/api/v1/oauth/token" \
		--header "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "client_id=${CLIENT_ID_BASIC}" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_secret=${CLIENT_SECRET_BASIC}")
	access_token=$(echo "$response" | plutil -extract access_token raw -)
	token_expires_in=$(echo "$response" | plutil -extract expires_in raw -)
	token_expiration_epoch=$(($current_epoch + $token_expires_in - 1))
}
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Check Token Expiration
# This function checks whether the token has expired. If no token exists, or the expiration has passed, 
# this function requests a new token and stores it in the $access_token variable.
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
checkTokenExpiration() {
	current_epoch=$(date +%s)
	if [[ token_expiration_epoch -ge current_epoch ]]
	then
		echo "Token valid until the following epoch time: " "$token_expiration_epoch"
	else
		echo "No valid token available, getting new token"
		getAccessToken
	fi
}
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Invalidate Token
# This function invalidates the current token and checks that the process completed successfully.
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
#
invalidateToken() {
	responseCode=$(curl -w "%{http_code}" -H "Authorization: Bearer ${access_token}" $JAMF_PRO_URL_BASIC/api/v1/auth/invalidate-token -X POST -s -o /dev/null)
	if [[ ${responseCode} == 204 ]]
	then
		echo "Token successfully invalidated"
		access_token=""
		token_expiration_epoch="0"
	elif [[ ${responseCode} == 401 ]]
	then
		echo "Token already invalid"
	else
		echo "An unknown error occurred invalidating the token"
	fi
}
#
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Check for Notifications
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
#
checkNotifications() {
	
	notificationsData=$(curl -s -H "Authorization: Bearer $access_token" "$url/api/v1/notifications") || return 1
	instanceName=$(echo "$url" | sed -E 's#https?://##; s/\..*//' | tr '[:lower:]' '[:upper:]')
	
	for notification in "${notificationsArr[@]}"; do
		if [[ "$notificationsData" == *"$notification"* ]]; then
			cleanString="${notification//_/ }"
			[[ "$cleanString" == "null" ]] && continue
			message="${instanceName} Notification: ${cleanString}"
			payload=$(cat <<EOF
{
	"text": "$message"
}
EOF
)
			# Send any Notifications to a Slack 
			curl -s -H "Content-Type: application/json" -d "$payload" "$slackWebhookURL"
			
		fi
	done
}
#
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# MAIN
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
#
checkTokenExpiration
checkNotifications 
invalidateToken 


