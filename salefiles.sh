# Plowshare salefiles.com module
# Copyright (c) 2015 Plowshare team
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.

MODULE_SALEFILES_REGEXP_URL='http://\(www\.\)\?salefiles\.com/[[:alnum:]]\+/\?.*'

MODULE_SALEFILES_DOWNLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account"
MODULE_SALEFILES_DOWNLOAD_RESUME=yes
MODULE_SALEFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=unused
MODULE_SALEFILES_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_SALEFILES_UPLOAD_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account (mandatory)"
MODULE_SALEFILES_UPLOAD_REMOTE_SUPPORT=no

MODULE_SALEFILES_DELETE_OPTIONS="
AUTH_FREE,b,auth-free,a=EMAIL:PASSWORD,Free account"

MODULE_SALEFILES_PROBE_OPTIONS=""

# Output a salefiles file download URL
# $1: cookie file (unused here)
# $2: salefiles url
# stdout: real file download link
salefiles_download() {
    local -r COOKIE_FILE=$1
    local -r URL=$2
    local -r BASE_URL='http://www.salefiles.com/'
    local PAGE FILE_URL FILE_NAME WAIT_LINE WAIT_TIME

    # .htm are redirected to .html
    if [ -n "$AUTH_FREE" ]; then
        salefiles_login "$AUTH_FREE" "$COOKIE_FILE" "$BASE_URL" || return
        PAGE=$(curl -L -b "$COOKIE_FILE" "$URL") || return
    else
        PAGE=$(curl -L -b "COOKIE_FILE" -c "$COOKIE_FILE" "$URL") || return
    fi

    #if match 'The file you were looking for could not be found' "$PAGE"; then
    if match 'File Not Found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # We are sorry, but your download request can not be processed right now.
    if match 'id="timeToWait"' "$PAGE"; then
        WAIT_LINE=$(echo "$PAGE" | parse_tag 'timeToWait' span)
        WAIT_TIME=${WAIT_LINE%% *}
        if match 'minute' "$WAIT_LINE"; then
            echo $(( WAIT_TIME * 60 ))
        else
            echo $((WAIT_TIME))
        fi
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FORM_HTML=$(grep_form_by_order "$PAGE" 2) || return
    FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
    FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
    FORM_FILENAME=$(parse_form_input_by_name 'fname' <<< "$FORM_HTML") || return
    FILE_NAME=$FORM_FILENAME
    FORM_METHOD_F=$(parse_form_input_by_name 'method_free' <<< "$FORM_HTML") || return
    FORM_ACTION=$FORM_ID

    # request download
    PAGE=$(curl -b "$COOKIE_FILE" -c "$COOKIE_FILE" -F "id=$FORM_ID" \
                                  -F "op=$FORM_OP" \
                                  -F "fname=$FORM_FILENAME" \
                                  -F "usr_login=" \
                                  -F "referer=" \
                                  -F "method_free=$FORM_METHOD_F" \
        "$URL") || return

    # check for forced delay
    WAIT=$(parse_quiet 'You have to wait .* till next download' \
        'wait \([[:digit:]]\+\)' <<< "$PAGE")

    if [ -n "$WAIT" ]; then
        log_error 'Forced delay between downloads.'
        # Note: Get rid of leading zeros so numbers will not be considered octal
        echo $(( (WAIT + 1) * 60 ))
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    # Free user can't download large files.
    if match "Free user can't download large files" "$PAGE" ; then
        return $ERR_LINK_NEED_PERMISSIONS
    fi

    # parse wait time
    WAIT=$(parse_quiet 'Wait ' \
        'Wait <.\+>\([[:digit:]]\+\)<.\+> seconds' <<< "$PAGE") || return

    # check for and handle CAPTCHA (if any)
    # Note: emulate 'grep_form_by_id_quiet'
    FORM_HTML=$(grep_form_by_name "$PAGE" 'F1' 2>/dev/null)

    if [ -n "$FORM_HTML" ]; then
        local RESP WORD ID CAPTCHA_DATA

        if match 'RecaptchaOptions' "$FORM_HTML"; then
            log_debug 'reCaptcha found'
            local CHALL
            local -r PUBKEY='6LcjQ-ISAAAAACC5Ym052eCQ-BYtMs7wkoCXd3du'

            RESP=$(recaptcha_process $PUBKEY) || return
            { read WORD; read CHALL; read ID; } <<< "$RESP"

            CAPTCHA_DATA="-F recaptcha_challenge_field=$CHALL -F recaptcha_response_field=$WORD"

        else
            log_error 'Unexpected content/captcha type. Site updated?'
            return $ERR_FATAL
        fi

        if [ -n "$WAIT" ]; then
            wait $(( WAIT + 1 )) || return
        fi

        log_debug "Captcha data: $CAPTCHA_DATA"

        FORM_ID=$(parse_form_input_by_name 'id' <<< "$FORM_HTML") || return
        FORM_ACTION=$FORM_ID
        FORM_OP=$(parse_form_input_by_name 'op' <<< "$FORM_HTML") || return
        FORM_RAND=$(parse_form_input_by_name 'rand' <<< "$FORM_HTML") || return

        PAGE=$(curl -i -b "$COOKIE_FILE" -c "$COOKIE_FILE" $CAPTCHA_DATA \
            -F "op=$FORM_OP" -F "id=$FORM_ID" -F "rand=$FORM_RAND" \
            -F 'referer='    -F "method_free=$FORM_METHOD_F" \
            "$URL") || return

        # Get error message, if any
        ERR=$(parse_tag_quiet '<div class="err"' 'div' <<< "$PAGE")

        if [ -n "$ERR" ]; then
            if match 'Wrong captcha' "$ERR"; then
                log_error 'Wrong captcha'
                captcha_nack "$ID"
                return $ERR_CAPTCHA
            fi

            log_debug 'Correct captcha'
            captcha_ack "$ID"
            log_error "Unexpected remote error: $ERR"
            return $ERR_FATAL
        fi

        log_debug 'Correct captcha'
        captcha_ack "$ID"

    else
        log_error 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    grep_http_header_location <<< "$PAGE" || return
    echo "$FILE_NAME"
}
