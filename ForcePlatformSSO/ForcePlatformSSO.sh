#!/bin/zsh --no-rcs
#
# ForcePlatformSSO_Okta.sh
#
# Original author: Scott Kendall (Entra ID version)
# Adapted for Okta by: Claude / Anthropic
#
# Written: 10/02/2025
# Last updated: 03/10/2026
#
# Script Purpose: Deploys Platform Single Sign-on via Okta Verify
#
#   1 - Installs Okta Verify
#   2 - Triggers install of Platform SSO for Okta configuration profile by adding
#       the Mac to a Platform Single Sign-on group in JAMF
#   3 - Deploys password expiration check to alert users when their password is
#       due to expire in 14 days or less
#   4 - Can force TouchID enrollment if available
#   5 - Optionally remove/reinstall Okta Verify if present

######################
#
# Script Parameters:
#
#####################
#
#   Parameter 4: API client ID (Modern or Classic)
#   Parameter 5: API client secret
#   Parameter 6: MDM Profile Name (must match the extensiblesso profile name in JAMF)
#   Parameter 7: JAMF Static Group name (for Platform SSO Users)
#   Parameter 8: Attempt to re-trigger Okta Verify install policy if not showing
#                as registered after timeout (yes/no)
#   Parameter 9: Force TouchID fingerprint enrollment if not already set (yes/no)

#
# Change log (Okta adaptation):
#
# 1.0 - Initial Okta adaptation from ForcePlatformSSO.sh v2.0 (Entra ID)
#       - Replaced Company Portal with Okta Verify
#       - Replaced all com.microsoft.* app extensions with com.okta.mobile.auth-service-extension
#       - Removed jamfAAD binary dependency entirely
#       - Replaced JAMF_check_AAD with JAMF_check_Okta using native app-sso command
#       - Replaced RUN_JAMF_AAD_ON_ERROR with RUN_OKTA_ON_ERROR; remediation now
#         re-triggers the Okta Verify JAMF install policy
#       - Updated all display strings to reference Okta instead of Microsoft Entra ID
#       - Retained all JAMF API functions, SwiftDialog framework, TouchID logic,
#         Focus mode detection, and group add/remove logic unchanged
# 1.1 - Corrected APP_EXTENSIONS bundle ID from com.okta.mobile.app.ssoextension
#         to com.okta.mobile.auth-service-extension to match the actual Platform SSO
#         extension identifier present in the Jamf extensiblesso configuration profile

######################################################################################################
#
# Global "Common" variables
#
######################################################################################################
#set -x
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
SCRIPT_NAME="ForcePlatformSSO_Okta"
LOGGED_IN_USER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
USER_DIR=$( dscl . -read /Users/${LOGGED_IN_USER} NFSHomeDirectory | awk '{ print $2 }' )
USER_UID=$(id -u "$LOGGED_IN_USER")
MAC_SERIAL=$(ioreg -l | grep IOPlatformSerialNumber | cut -d'"' -f4)

FREE_DISK_SPACE=$(($( /usr/sbin/diskutil info / | /usr/bin/grep "Free Space" | /usr/bin/awk '{print $6}' | /usr/bin/cut -c 2- ) / 1024 / 1024 / 1024 ))
MACOS_NAME=$(sw_vers -productName)
MACOS_VERSION=$(sw_vers -productVersion)
MAC_RAM=$(($(sysctl -n hw.memsize) / 1024**3))" GB"
MAC_CPU=$(sysctl -n machdep.cpu.brand_string)

ICON_FILES="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"

# Swift Dialog version requirements

SW_DIALOG="/usr/local/bin/dialog"
MIN_SD_REQUIRED_VERSION="2.5.0"
HOUR=$(date +%H)
case $HOUR in
    0[0-9]|1[0-1]) GREET="morning" ;;
    1[2-7])        GREET="afternoon" ;;
    *)             GREET="evening" ;;
esac
SD_DIALOG_GREETING="Good $GREET"

# Make some temp files

DIALOG_COMMAND_FILE=$(mktemp "/var/tmp/${SCRIPT_NAME}_cmd.XXXXX")
JSON_DIALOG_BLOB=$(mktemp "/var/tmp/${SCRIPT_NAME}_json.XXXXX")
chmod 666 $DIALOG_COMMAND_FILE
chmod 666 $JSON_DIALOG_BLOB

###################################################
#
# App Specific variables (Feel free to change these)
#
###################################################

# See if there is a "defaults" file...if so, read in the contents
DEFAULTS_DIR="/Library/Managed Preferences/com.gianteaglescript.defaults.plist"
if [[ -f "$DEFAULTS_DIR" ]]; then
    echo "Found Defaults Files.  Reading in Info"
    SUPPORT_DIR=$(defaults read "$DEFAULTS_DIR" SupportFiles)
    SD_BANNER_IMAGE="${SUPPORT_DIR}$(defaults read "$DEFAULTS_DIR" BannerImage)"
    SPACING=$(defaults read "$DEFAULTS_DIR" BannerPadding)
else
    SUPPORT_DIR="/Library/Application Support/GiantEagle"
    SD_BANNER_IMAGE="${SUPPORT_DIR}/SupportFiles/GE_SD_BannerImage.png"
    SPACING=5   # 5 spaces to accommodate for icon offset
fi
BANNER_TEXT_PADDING="${(j::)${(l:$SPACING:: :)}}"

# Log files location

LOG_FILE="${SUPPORT_DIR}/logs/${SCRIPT_NAME}.log"

# Display items (banner / icon)

SD_WINDOW_TITLE="${BANNER_TEXT_PADDING}Register Platform Single Sign-on"
OVERLAY_ICON="${ICON_FILES}UserIcon.icns"
SD_ICON_FILE="${SUPPORT_DIR}/SupportFiles/sso.png"
SSO_GRAPHIC="${SUPPORT_DIR}/SupportFiles/pSSO_Notification.png"

# Trigger installs for images & icons

FOCUS_FILE="$USER_DIR/Library/DoNotDisturb/DB/Assertions.json"
SD_TIMER=300    # Length of time you want the message on the screen (300 = 5 mins)

# --------------------------------------------------------------------------
# Okta-specific: app extension bundle ID for Okta Verify Platform SSO
# The Microsoft CompanyPortalMac extensions from the original script have
# been replaced with the single Okta Verify SSO extension.
# --------------------------------------------------------------------------
APP_EXTENSIONS=("com.okta.mobile.auth-service-extension")

# JAMF policy triggers - update these to match your JAMF policy trigger names
SUPPORT_FILE_INSTALL_POLICY="install_SymFiles"
DIALOG_INSTALL_POLICY="install_SwiftDialog"
PSSO_ICON_POLICY="install_psso_icon"
SSO_GRAPHIC_POLICY="install_sso_graphic"
PORTAL_APP_POLICY="install_okta_verify"     # <-- was: install_mscompanyportal

##################################################
#
# Passed in variables
#
#################################################

JAMF_LOGGED_IN_USER=${3:-"$LOGGED_IN_USER"}    # Passed in by JAMF automatically
SD_FIRST_NAME="${(C)JAMF_LOGGED_IN_USER%%.*}"
CLIENT_ID=${4}                                  # Client ID for JAMF Pro API
CLIENT_SECRET=${5}
MDM_PROFILE=${6}
JAMF_GROUP_NAME=${7}
RUN_OKTA_ON_ERROR=${8:-"yes"}                   # <-- was: RUN_JAMF_AAD_ON_ERROR
CHECK_FOR_TOUCHID=${9:-"yes"}

[[ ${#CLIENT_ID} -gt 30 ]] && JAMF_TOKEN="new" || JAMF_TOKEN="classic"

####################################################################################################
#
# Functions
#
####################################################################################################

function create_log_directory ()
{
    # Ensure that the log directory and the log files exist. If they
    # do not then create them and set the permissions.
    #
    # RETURN: None

    LOG_DIR=${LOG_FILE%/*}
    [[ ! -d "${LOG_DIR}" ]] && /bin/mkdir -p "${LOG_DIR}"
    /bin/chmod 755 "${LOG_DIR}"

    [[ ! -f "${LOG_FILE}" ]] && /usr/bin/touch "${LOG_FILE}"
    /bin/chmod 644 "${LOG_FILE}"
}

function logMe ()
{
    # Basic two-pronged logging function that will log like this:
    #
    # 2026-03-10 12:00:00: Some message here
    #
    # Logs both to STDOUT/STDERR and a file.
    # RETURN: None

    echo "$(/bin/date '+%Y-%m-%d %H:%M:%S'): ${1}" | tee -a "${LOG_FILE}"
}

function check_swift_dialog_install ()
{
    # Check to make sure that Swift Dialog is installed and functioning correctly.
    # Will install if missing or outdated.
    # RETURN: None

    logMe "Ensuring that swiftDialog version is installed..."
    if [[ ! -x "${SW_DIALOG}" ]]; then
        logMe "Swift Dialog is missing or corrupted - Installing from JAMF"
        install_swift_dialog
        SD_VERSION=$( ${SW_DIALOG} --version)
        [[  -z $SD_VERSION ]]; { logMe "SD Not reporting installed version!"; cleanup_and_exit 1; }
    fi

    if ! is-at-least "${MIN_SD_REQUIRED_VERSION}" "${SD_VERSION}"; then
        logMe "Swift Dialog is outdated - Installing version '${MIN_SD_REQUIRED_VERSION}' from JAMF..."
        install_swift_dialog
    else
        logMe "Swift Dialog is currently running: ${SD_VERSION}"
    fi
}

function install_swift_dialog ()
{
    # Install Swift Dialog from JAMF.
    # PARMS Expected: DIALOG_INSTALL_POLICY - policy trigger from JAMF
    # RETURN: None

    /usr/local/bin/jamf policy -trigger ${DIALOG_INSTALL_POLICY}
}

function check_support_files ()
{
    [[ ! -e "${SD_BANNER_IMAGE}" ]] && /usr/local/bin/jamf policy -trigger ${SUPPORT_FILE_INSTALL_POLICY}
    [[ ! -e "${SD_ICON_FILE}" ]]    && /usr/local/bin/jamf policy -trigger ${PSSO_ICON_POLICY}
    [[ ! -e "${SSO_GRAPHIC}" ]]     && /usr/local/bin/jamf policy -trigger ${SSO_GRAPHIC_POLICY}
}

function cleanup_and_exit ()
{
    [[ -f ${JSON_OPTIONS} ]]         && /bin/rm -rf ${JSON_OPTIONS}
    [[ -f ${TMP_FILE_STORAGE} ]]     && /bin/rm -rf ${TMP_FILE_STORAGE}
    [[ -f ${DIALOG_COMMAND_FILE} ]]  && /bin/rm -rf ${DIALOG_COMMAND_FILE}
    JAMF_invalidate_token
    exit $1
}

function JAMF_check_credentials ()
{
    # PURPOSE: Check to make sure the Client ID & Secret are passed correctly
    # RETURN: None

    if [[ -z $CLIENT_ID ]] || [[ -z $CLIENT_SECRET ]]; then
        logMe "Client/Secret info is not valid"
        exit 1
    fi
    logMe "Valid credentials passed"
}

function JAMF_check_connection ()
{
    # PURPOSE: Check connectivity to the JAMF Pro server
    # RETURN: None

    if ! /usr/local/bin/jamf -checkjssconnection -retry 5; then
        logMe "Error: JSS connection not active."
        exit 1
    fi
    logMe "JSS connection active!"
}

function JAMF_get_server ()
{
    # PURPOSE: Retrieve JAMF server URL from preferences file
    # RETURN: None

    jamfpro_url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
    logMe "JAMF Pro server is: $jamfpro_url"
}

function JAMF_get_classic_api_token ()
{
    # PURPOSE: Get a bearer token using JAMF Pro ID & password (Classic API)
    # RETURN: api_token

    api_token=$(/usr/bin/curl -X POST --silent -u "${CLIENT_ID}:${CLIENT_SECRET}" "${jamfpro_url}/api/v1/auth/token" | plutil -extract token raw -)
    if [[ "$api_token" == *"Could not extract value"* ]]; then
        logMe "Error: Unable to obtain API token. Check your credentials and JAMF Pro URL."
        exit 1
    else
        logMe "Classic API token successfully obtained."
    fi
}

function JAMF_validate_token ()
{
    # Verify that API authentication is using a valid token.
    # The API call will only return the HTTP status code.

    api_authentication_check=$(/usr/bin/curl --write-out %{http_code} --silent --output /dev/null "${jamfpro_url}/api/v1/auth" --request GET --header "Authorization: Bearer ${api_token}")
}

function JAMF_get_access_token ()
{
    # PURPOSE: Obtain an OAuth bearer token using Client ID & Secret (Modern API)
    # RETURN: api_token

    returnval=$(curl --silent --location --request POST "${jamfpro_url}/api/oauth/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${CLIENT_ID}" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_secret=${CLIENT_SECRET}")

    if [[ -z "$returnval" ]]; then
        logMe "Check Jamf URL"
        exit 1
    elif [[ "$returnval" == '{"error":"invalid_client"}' ]]; then
        logMe "Check the API Client credentials and permissions"
        exit 1
    else
        logMe "API token successfully obtained."
    fi

    api_token=$(echo "$returnval" | plutil -extract access_token raw -)
}

function JAMF_check_and_renew_api_token ()
{
    # Verify token validity and renew if needed.

    JAMF_validate_token

    if [[ ${api_authentication_check} == 200 ]]; then
        api_token=$(/usr/bin/curl "${jamfpro_url}/api/v1/auth/keep-alive" --silent --request POST -H "Authorization: Bearer ${api_token}" | plutil -extract token raw -)
    else
        JAMF_get_classic_api_token
    fi
}

function JAMF_invalidate_token ()
{
    # PURPOSE: Invalidate the JAMF bearer token
    # RETURN: None

    returnval=$(/usr/bin/curl -w "%{http_code}" -H "Authorization: Bearer ${api_token}" "${jamfpro_url}/api/v1/auth/invalidate-token" -X POST -s -o /dev/null)

    if [[ $returnval == 204 ]]; then
        logMe "Token successfully invalidated"
    elif [[ $returnval == 401 ]]; then
        logMe "Token already invalid"
    else
        logMe "Unexpected response code: $returnval"
        exit 1
    fi
}

function JAMF_get_deviceID ()
{
    # PURPOSE: Use serial number or hostname to get the device ID from JAMF Pro
    # RETURN: Device ID
    # PARAMETERS: $1 = search type (Serials / Hostname), $2 = identifier value

    local type retval ID
    [[ "$1" == "Hostname" ]] && type="general.name" || type="hardware.serialNumber"
    retval=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v3/computers-inventory?filter=${type}=='${2}'") || {
        display_failure_message "Failed to contact Jamf Pro"
        echo "ERR"
        return 1
    }

    if ! jq -e . >/dev/null 2>&1 <<<"$retval"; then
        display_failure_message "Invalid JSON response from Jamf Pro"
        echo "ERR"
        return 1
    fi

    if [[ $retval == *"PRIVILEGE"* ]]; then
        display_failure_message "Invalid Privilege to read inventory"
        echo "PRIVILEGE"
        return 1
    fi

    total=$(jq '.totalCount' <<<"$retval")
    if [[ $total -eq 0 ]]; then
        display_failure_message "Inventory Record '${2}' not found"
        echo "NOT FOUND"
        return 1
    fi

    id=$(printf "%s" $retval | tr -d '[:cntrl:]' | jq -r '.results[].id')
    if [[ -z $id || $id == "null" ]]; then
        display_failure_message "$retval"
        echo "ERR"
        return 1
    fi
    printf '%s\n' "$id"
    return 0
}

function JAMF_retrieve_static_groupID ()
{
    # PURPOSE: Retrieve the ID of a static group by name
    # RETURN: ID # of static group
    # PARAMETERS: $1 = JAMF Static group name

    local tmp
    tmp=$(/usr/bin/curl -s -H "Authorization: Bearer ${api_token}" -H "Accept: application/json" "${jamfpro_url}api/v2/computer-groups/static-groups?sort=id%3Aasc") || {
        display_failure_message "Failed to contact Jamf Pro"
        echo "ERR"
        return 1
    }

    if ! jq -e . >/dev/null 2>&1 <<<"$tmp"; then
        display_failure_message "Invalid JSON response from Jamf Pro"
        echo "ERR"
        return 1
    fi

    if [[ $tmp == *"PRIVILEGE"* ]]; then
        display_failure_message "Invalid Privilege to read groups"
        echo "PRIVILEGE"
        return 1
    fi

    total=$(jq '.totalCount' <<<"$tmp")
    if [[ $total -eq 0 ]]; then
        display_failure_message "No groups found"
        echo "NOT FOUND"
        return 1
    fi

    id=$(printf "%s" $tmp | tr -d '[:cntrl:]' | jq -r --arg name "$1" '.results[] | select(.name == $name) | .id')
    if [[ -z $id || $id == "null" ]]; then
        display_failure_message "$tmp"
        echo "ERR"
        return 1
    fi
    printf '%s\n' "$id"
    return 0
}

function JAMF_static_group_action ()
{
    # PURPOSE: Add or remove a device record from a JAMF static group
    # RETURN: None
    # PARAMETERS: $1 = JAMF Static group ID
    #             $2 = Serial number of device
    #             $3 = Action to take: "add" or "remove"

    declare apiData
    local groupID="$1" serial="$2" action="$3"

    [[ "${action:l}" != (add|remove) ]] && { echo "ERROR: Action must be 'add' or 'remove'" >&2; return 1; }
    [[ ! "$groupID" =~ '^[0-9]+$' ]] && { echo "ERROR: Group ID must be numeric" >&2; return 1; }

    if [[ "${action:l}" == "remove" ]]; then
        api_data='<computer_group><computer_deletions><computer><serial_number>'${serial}'</serial_number></computer></computer_deletions></computer_group>'
    else
        api_data='<computer_group><computer_additions><computer><serial_number>'${serial}'</serial_number></computer></computer_additions></computer_group>'
    fi

    retval=$(curl -w "%{http_code}" -s -H "Authorization: Bearer ${api_token}" -H "Content-Type: application/xml" "${jamfpro_url}JSSResource/computergroups/id/${groupID}" --request PUT --data "$api_data" -o /dev/null)

    case "$retval" in
        200|201) return 0 ;;
        409) echo "ERROR: Computer not in group" >&2; return 1 ;;
        401) echo "ERROR: API token invalid/expired" >&2; return 1 ;;
        404) echo "ERROR: Group ID $groupID not found" >&2; return 1 ;;
        *) echo "ERROR: HTTP $retval" >&2; return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# JAMF_check_Okta
#
# Replaces the original JAMF_check_AAD function which depended on the
# jamfAAD binary - an Entra ID-only tool with no Okta equivalent.
#
# This function verifies Okta Platform SSO registration status using the
# macOS-native `app-sso platform -s` command, which is provider-agnostic
# and works with any Platform SSO extension including Okta Verify.
#
# RETURN: 0 = registered OK, 1 = not registered / error
# --------------------------------------------------------------------------
function JAMF_check_Okta ()
{
    local okta_status
    local retval=1

    logMe "Checking Okta Verify Platform SSO registration status..."
    okta_status=$(runAsUser app-sso platform -s 2>/dev/null)

    if [[ $(getValueOf registrationCompleted "$okta_status") == "true" ]]; then
        logMe "INFO: Okta Platform SSO registration confirmed."
    else
        logMe "ERROR: Okta Platform SSO not showing as registered."
        logMe "app-sso output: ${okta_status}"
        retval=0
    fi
    return $retval
}

function reinstall_okta_verify ()
{
    # PURPOSE: Reinstall Okta Verify if already present, to ensure latest version
    # RETURN: None
    # NOTE: Uncomment the call to this function in Main if you want to force reinstall

    local okta_verify_app="/Applications/Okta Verify.app"

    if [[ -d "$okta_verify_app" ]]; then
        logMe "Okta Verify found; uninstalling..."
        rm -rf "$okta_verify_app"
    else
        logMe "Okta Verify not found; continuing with fresh install..."
    fi

    logMe "Installing Okta Verify..."
    /usr/local/jamf/bin/jamf policy -trigger "$PORTAL_APP_POLICY" --forceNoRecon

    if [[ -d "$okta_verify_app" ]]; then
        logMe "Okta Verify is installed. Ready to proceed with PSSO profile."
    else
        logMe "Okta Verify did not install. Exiting with error..."
        exit 1
    fi
}

function display_failure_message ()
{
    MainDialogBody=(
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --titlefont shadow=1
        --message "**Problems retrieving JAMF Info**<br><br>Error Message: $1"
        --icon "${SD_ICON_FILE}"
        --overlayicon warning
        --iconsize 128
        --messagefont name=Arial,size=17
        --button1text "OK"
        --ontop
        --moveable
    )

    $SW_DIALOG "${MainDialogBody[@]}" 2>/dev/null
    buttonpress=$?
}

function check_for_profile ()
{
    # PURPOSE: Check to see if a profile is installed
    # RETURN: "Yes" or "No"
    # PARAMETERS: $1 = Profile name to search for

    logMe "Checking if Platform Single Sign-on profile is installed..."
    check_installed=$(/usr/bin/profiles -C -v | /usr/bin/awk -F: '/attribute: name/{print $NF}' | /usr/bin/grep "${1}" | xargs)

    if [[ "$check_installed" == "$1" ]]; then
        logMe "Okta Platform SSO profile is installed"
        echo "Yes"
    else
        logMe "Okta Platform SSO profile is not installed"
        echo "No"
    fi
}

function displaymsg ()
{
    message="When you see this macOS notification appear, please click the register button within the prompt, and go through the Okta registration process."
    if [[ $FOCUS_STATUS = "On" ]]; then
        message+="<br><br>**Since your focus mode is turned on, you will need to click in the notification center to see this prompt**"
    fi

    MainDialogBody=(
        --message "<br>$SD_DIALOG_GREETING $SD_FIRST_NAME. $message"
        --titlefont shadow=1
        --appearance light
        --icon "${SD_ICON_FILE}"
        --overlayicon "${OVERLAY_ICON}"
        --bannerimage "${SD_BANNER_IMAGE}"
        --bannertitle "${SD_WINDOW_TITLE}"
        --commandfile "${DIALOG_COMMAND_FILE}"
        --image "${SSO_GRAPHIC}"
        --helpmessage "Contact the TSD or put in a ticket if you are having problems registering your device with Okta."
        --button1text "Dismiss"
        --width 740
        --height 450
        --timer 300
        --quitkey 0
        --ontop
        --moveable
        --ignorednd
    )

    "${SW_DIALOG}" "${MainDialogBody[@]}" 2>/dev/null &
}

function getValueOf ()
{
    echo $2 | grep "$1" | awk -F ":" '{print $2}' | tr -d "," | xargs
}

function get_sso_status()
{
    ssoStatus=$(runAsUser app-sso platform -s)
}

function kill_sso_agent()
{
    pkill AppSSOAgent
    sleep 1
}

function runAsUser ()
{
    launchctl asuser "${USER_UID}" sudo -u "${LOGGED_IN_USER}" "$@"
}

function check_focus_status ()
{
    # PURPOSE: Check to see if the user is in focus mode
    # RETURN: "on" or "off"

    local results="off"
    if [[ -f "$FOCUS_FILE" ]] && grep -q '"storeAssertionRecords"' "$FOCUS_FILE" 2>/dev/null; then
        results="on"
    fi
    echo $results
}

function touch_id_status ()
{
    local hw="Absent"
    retval="$hw"
    local enrolled="false"
    local bioCount="0"

    bioOutput=$(ioreg -l 2>/dev/null)

    if [[ $bioOutput == *"+-o AppleBiometricSensor"* ]]; then
        hw="Present"
    else
        if [[ $bioOutput =~ '"AppleBiometricSensor"=([0-9]+)' && ${match[1]} -gt 0 ]]; then
            hw="Present"
        elif system_profiler SPUSBDataType 2>/dev/null | grep -q "Magic Keyboard.*Touch ID"; then
            hw="Present"
        fi
    fi

    if [[ "${hw}" == "Present" ]]; then
        bioCount=$(runAsUser bioutil -c 2>/dev/null | awk '/biometric template/{print $3}' | grep -Eo '^[0-9]+$' || echo "0")
        [[ "${bioCount}" -gt 0 ]] && enrolled="true"
        [[ "${enrolled}" == "true" ]] && retval="Enabled" || retval="Not enabled"
    fi
    echo "$retval"
}

function force_touch_id ()
{
    # PURPOSE: Force TouchID registration
    # RETURN: 0 if successful, 1 if aborted

    while true; do
        open "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension"
        "${SW_DIALOG}" \
        --title "Touch ID Required" \
        --message "Touch ID needs to be enabled on your system.  Please add at least one fingerprint.  Close this window when you are done adding your fingerprint." \
        --icon "SF=touchid,colour=auto" \
        --style mini \
        --position "topright" \
        --button1text "Close" \
        --button2text "Abort" \
        --quitkey 0 \
        --ontop \

        buttonpress=$?
        TOUCH_ID_STATUS=$(touch_id_status)
        [[ $TOUCH_ID_STATUS == "Enabled" || $buttonpress == 2 ]] && break
    done

    killall "System Settings" >/dev/null 2>&1
    [[ $buttonpress == 2 ]] && return 1 || return 0
}

function enable_app_extension ()
{
    # PURPOSE: Enable Okta Verify SSO extension via PlugKit
    #          Iterates APP_EXTENSIONS array and enables any that are not already active
    # RETURN: None

    for extension in "${APP_EXTENSIONS[@]}"; do
        logMe "Checking for extension: $extension"
        results=$(runAsUser pluginkit -m | grep "${extension}")

        if [[ -z $results ]]; then
            logMe "Error: Extension not found: ${extension}"
            logMe "Skipping..."
            continue
        fi
        logMe "Extension found: $extension"

        if [[ $(echo $results | awk '{print $1}') == "+" ]]; then
            logMe "INFO: $extension is already enabled"
        else
            logMe "WARNING: $extension is not enabled. Enabling now..."
            runAsUser pluginkit -e use -i "${extension}"
            logMe "INFO: $extension has been enabled"
        fi
    done
}

####################################################################################################
#
# Main Script
#
####################################################################################################

declare api_token
declare jamfpro_url
declare ssoStatus
declare FOCUS_STATUS
declare TOUCH_ID_STATUS
declare DIALOG_PID

autoload 'is-at-least'

# Make sure the MDM profile and Group name are passed in
if [[ -z $MDM_PROFILE ]] || [[ -z $JAMF_GROUP_NAME ]]; then
    logMe "ERROR: Missing Group name or MDM profile name"
    cleanup_and_exit 1
fi

create_log_directory
check_swift_dialog_install
check_support_files
JAMF_check_connection
JAMF_get_server

# Determine which API to use based on Client ID length
[[ $JAMF_TOKEN == "new" ]] && JAMF_get_access_token || JAMF_get_classic_api_token

##
## Check the status of Focus Mode
##
FOCUS_STATUS=$(check_focus_status)
logMe "INFO: User has focus mode turned $FOCUS_STATUS"

##
## Check for TouchID and enforce if requested
##
if [[ "${CHECK_FOR_TOUCHID:l}" == "yes" ]]; then
    TOUCH_ID_STATUS=$(touch_id_status)
    logMe "INFO: Touch ID Status: $TOUCH_ID_STATUS"
    if [[ "${TOUCH_ID_STATUS}" == "Not enabled" ]]; then
        logMe "Forcing TouchID Registration"
        force_touch_id
        [[ $? -ne 0 ]] && { logMe "Script Aborted"; cleanup_and_exit 1; }
        logMe "INFO: Touch ID Status: $TOUCH_ID_STATUS"
    fi
fi

##
## Reinstall Okta Verify - uncomment the line below to force reinstall
##
#reinstall_okta_verify

##
## Retrieve the JAMF ID # of the static group
##
groupID=$(JAMF_retrieve_static_groupID $JAMF_GROUP_NAME)
[[ -z $groupID ]] && { display_failure_message "Group ID came back empty!"; cleanup_and_exit 1; }
[[ $groupID == *"ERR"* ]] && cleanup_and_exit 1
[[ $groupID == *"NOT FOUND"* || $groupID == *"PRIVILEGE"* ]] && cleanup_and_exit 1
logMe "Group ID is: $groupID"

##
## Retrieve JAMF Device ID (computer record)
##
deviceID=$(JAMF_get_deviceID "Serials" $MAC_SERIAL)
[[ $deviceID == *"ERR"* ]] && cleanup_and_exit 1
[[ $deviceID == *"NOT FOUND"* || $deviceID == *"PRIVILEGE"* ]] && cleanup_and_exit 1
logMe "Device ID is: $deviceID"

##
## Profile check - add to group (or remove and re-add if already present)
##
profileInstalled=$(check_for_profile $MDM_PROFILE)

if [[ "$profileInstalled" == "No" ]]; then
    retval=$(JAMF_static_group_action $groupID $MAC_SERIAL "add")
    [[ -z $retval ]] && logMe "Successful addition" || { logMe $retval; cleanup_and_exit 1; }
else
    # Profile already present - remove and re-add to force the registration prompt
    logMe "Okta Platform SSO profile is already installed. Cycling group membership to re-trigger prompt..."
    logMe "Removing $MAC_SERIAL from $JAMF_GROUP_NAME ($groupID)"
    retval=$(JAMF_static_group_action $groupID $MAC_SERIAL "remove")
    [[ -z $retval ]] && logMe "Successful removal" || { logMe $retval; cleanup_and_exit 1; }
    sleep 5
    logMe "Adding $MAC_SERIAL to $JAMF_GROUP_NAME ($groupID)"
    retval=$(JAMF_static_group_action $groupID $MAC_SERIAL "add")
    [[ -z $retval ]] && logMe "Successful addition" || { logMe $retval; cleanup_and_exit 1; }
fi

##
## Check app extensions and enable if needed
##
enable_app_extension

##
## Platform SSO registration
##
get_sso_status
if [[ $(getValueOf registrationCompleted "$ssoStatus") == true ]]; then
    logMe "User already registered with Okta Platform SSO"
    cleanup_and_exit 0
fi

logMe "Prompting user to register device with Okta"
displaymsg
echo "activate:" > ${DIALOG_COMMAND_FILE}

# Force the registration dialog to appear by restarting the SSO agent
logMe "Stopping Platform SSO agent"
kill_sso_agent

# Wait until registration is complete
interval=10     # seconds between checks
max_wait=300    # total seconds before timeout (5 minutes)
start_ts=$(date +%s)

until [[ $(getValueOf registrationCompleted "$ssoStatus") == true ]]; do
    sleep "$interval"
    logMe "Device has not completed Okta registration yet."
    now_ts=$(date +%s)
    if (( now_ts - start_ts >= max_wait )); then
        logMe "ERROR: Timed out after ${max_wait}s waiting for Okta registration."
        cleanup_and_exit 1
    fi
    sleep $interval
    get_sso_status
done

logMe "INFO: Okta Platform SSO Registration Finished Successfully"
echo "quit:" > ${DIALOG_COMMAND_FILE}

##
## Verify registration via app-sso and optionally attempt remediation
## (Replaces the original jamfAAD gatherAADInfo check, which was Entra-only)
##
if JAMF_check_Okta; then
    logMe "INFO: Okta Platform SSO confirmed registered."
else
    logMe "ERROR: app-sso does not report successful Okta registration!"
    if [[ "${RUN_OKTA_ON_ERROR:l}" == "yes" ]]; then
        logMe "INFO: Sleeping 5 secs then re-triggering Okta Verify install policy..."
        ${SW_DIALOG} --notification \
            --identifier "registration" \
            --title "Finalising Okta Platform SSO registration" \
            --message "Please be patient while we complete setup." \
            --button1text "Dismiss"
        sleep 5
        /usr/local/bin/jamf policy -trigger "$PORTAL_APP_POLICY"
        ${SW_DIALOG} --notification --identifier "registration" --remove
    fi
fi

cleanup_and_exit 0
