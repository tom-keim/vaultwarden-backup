#!/bin/bash

ENV_FILE="/.env"
CRON_CONFIG_FILE="${HOME}/crontabs"
BACKUP_DIR="/bitwarden/backup"
RESTORE_DIR="/bitwarden/restore"
RESTORE_EXTRACT_DIR="/bitwarden/extract"

#################### Function ####################
########################################
# Print colorful message.
# Arguments:
#     color
#     message
# Outputs:
#     colorful message
########################################
function color() {
    case $1 in
        red)     echo -e "\033[31m$2\033[0m" ;;
        green)   echo -e "\033[32m$2\033[0m" ;;
        yellow)  echo -e "\033[33m$2\033[0m" ;;
        blue)    echo -e "\033[34m$2\033[0m" ;;
        none)    echo "$2" ;;
    esac
}

########################################
# Check storage system connection success.
# Arguments:
#     None
########################################
function check_rclone_connection() {
    # check configuration exist
    rclone ${RCLONE_GLOBAL_FLAG} config show "${RCLONE_REMOTE_NAME}" > /dev/null 2>&1
    if [[ $? != 0 ]]; then
        color red "rclone configuration information not found"
        color blue "Please configure rclone first, check https://github.com/ttionya/vaultwarden-backup/blob/master/README.md#backup"
        exit 1
    fi

    # check connection
    local HAS_ERROR="FALSE"

    for RCLONE_REMOTE_X in "${RCLONE_REMOTE_LIST[@]}"
    do
        rclone ${RCLONE_GLOBAL_FLAG} mkdir "${RCLONE_REMOTE_X}"
        if [[ $? != 0 ]]; then
            color red "storage system connection failure $(color yellow "[${RCLONE_REMOTE_X}]")"

            HAS_ERROR="TRUE"
        fi
    done

    if [[ "${HAS_ERROR}" == "TRUE" ]]; then
        exit 1
    fi
}

########################################
# Check file is exist.
# Arguments:
#     file
########################################
function check_file_exist() {
    if [[ ! -f "$1" ]]; then
        color red "cannot access $1: No such file"
        exit 1
    fi
}

########################################
# Check directory is exist.
# Arguments:
#     directory
########################################
function check_dir_exist() {
    if [[ ! -d "$1" ]]; then
        color red "cannot access $1: No such directory"
        exit 1
    fi
}

########################################
# Send mail by s-nail.
# Arguments:
#     mail subject
#     mail content
# Outputs:
#     send mail result
########################################
function send_mail() {
    if [[ "${MAIL_DEBUG}" == "TRUE" ]]; then
        local MAIL_VERBOSE="-v"
    fi

    echo "$2" | mail ${MAIL_VERBOSE} -s "$1" ${MAIL_SMTP_VARIABLES} "${MAIL_TO}"
    if [[ $? != 0 ]]; then
        color red "mail sending has failed"
    else
        color blue "mail has been sent successfully"
    fi
}

########################################
# Send mail.
# Arguments:
#     backup successful
#     mail content
########################################
function send_mail_content() {
    if [[ "${MAIL_SMTP_ENABLE}" == "FALSE" ]]; then
        return
    fi

    # successful
    if [[ "$1" == "TRUE" && "${MAIL_WHEN_SUCCESS}" == "TRUE" ]]; then
        send_mail "vaultwarden Backup Success" "$2"
    fi

    # failed
    if [[ "$1" == "FALSE" && "${MAIL_WHEN_FAILURE}" == "TRUE" ]]; then
        send_mail "vaultwarden Backup Failed" "$2"
    fi
}

########################################
# Send health check ping.
# Arguments:
#     url
#     ping name
########################################
function send_ping() {
    if [[ -z "$1" ]]; then
        return
    fi

    wget "$1" -T 15 -t 10 -O /dev/null -q
    if [[ $? != 0 ]]; then
        color red "$2 ping sending has failed"
    else
        color blue "$2 ping has been sent successfully"
    fi
}



########################################
# Send ntfy message
# Arguments:
#     ntfy subject
#     ntfy content
#     ntfy priority
# Outputs:
#     ntfy send result
########################################
function send_ntfy() {

    if [[ -z $NTFY_SERVER ]]; then
        color red "No ntfy server configured"
        exit 0
    fi

    # Initialize the curl command
    curl_cmd="curl -s -w '%{http_code}' -o /dev/stdout"

    # Add the authentication header based on available credentials
    if [[ -n "$NTFY_PASSWORD" ]]; then
        auth_base64=$(echo -n "$NTFY_USERNAME:$NTFY_PASSWORD" | base64 -w 0)
        curl_cmd+=" -H 'Authorization: Basic $auth_base64'"
    elif [[ -n "$NTFY_TOKEN" ]]; then
        curl_cmd+=" -H \"Authorization: Bearer $NTFY_TOKEN\""
    fi

    # Add other headers and options
    curl_cmd+=" -H 'Title: $1' -H 'X-Priority: $3' -d '$2' '$NTFY_SERVER/$NTFY_TOPIC'"


    # Execute the constructed curl command
    response=$(eval $curl_cmd)

    # Extract the HTTP response code (last 3 characters of the response)
    response_code="${response: -3}"

    # Extract the response body (all except the last 3 characters)
    response_body="${response:0:-3}"

    # Check the HTTP response code
    if [[ "$response_code" -eq 200 ]]; then
        color blue "ntfy has been sent successfully"
    else
        color red "ntfy sending has failed with response code $response_code"
        echo "Response body:"
        echo "$response_body"
    fi
    
}


########################################
# Send ntfy message content
# Arguments:
#     backup succesfull
#     notification content
########################################
function send_ntfy_content() {
    if [[ "${NTFY_ENABLE}" == "FALSE" ]]; then
        return
    fi


    # successful
    if [[ "$1" == "TRUE" && "${NTFY_WHEN_SUCCESS}" == "TRUE" ]]; then
        send_ntfy "vaultwarden Backup Success" "$2" "$NTFY_PRIORITY_SUCCESS"
    fi

    # failed
    if [[ "$1" == "FALSE" && "${NTFY_WHEN_FAILURE}" == "TRUE" ]]; then
        send_ntfy "vaultwarden Backup Failed" "$2" "$NTFY_PRIORITY_FAILURE"
    fi

}

########################################
# Configure PostgreSQL password file.
# Arguments:
#     None
########################################
function configure_postgresql() {
    if [[ "${DB_TYPE}" == "POSTGRESQL" ]]; then
        echo "${PG_HOST}:${PG_PORT}:${PG_DBNAME}:${PG_USERNAME}:${PG_PASSWORD}" > ~/.pgpass
        chmod 0600 ~/.pgpass
    fi
}

########################################
# Export variables from .env file.
# Arguments:
#     None
# Outputs:
#     variables with prefix 'DOTENV_'
# Reference:
#     https://gist.github.com/judy2k/7656bfe3b322d669ef75364a46327836#gistcomment-3632918
########################################
function export_env_file() {
    if [[ -f "${ENV_FILE}" ]]; then
        color blue "find \"${ENV_FILE}\" file and export variables"
        set -a
        source <(cat "${ENV_FILE}" | sed -e '/^#/d;/^\s*$/d' -e 's/\(\w*\)[ \t]*=[ \t]*\(.*\)/DOTENV_\1=\2/')
        set +a
    fi
}

########################################
# Get variables from
#     environment variables,
#     secret file in environment variables,
#     secret file in .env file,
#     environment variables in .env file.
# Arguments:
#     variable name
# Outputs:
#     variable value
########################################
function get_env() {
    local VAR="$1"
    local VAR_FILE="${VAR}_FILE"
    local VAR_DOTENV="DOTENV_${VAR}"
    local VAR_DOTENV_FILE="DOTENV_${VAR_FILE}"
    local VALUE=""

    if [[ -n "${!VAR:-}" ]]; then
        VALUE="${!VAR}"
    elif [[ -n "${!VAR_FILE:-}" ]]; then
        VALUE="$(cat "${!VAR_FILE}")"
    elif [[ -n "${!VAR_DOTENV_FILE:-}" ]]; then
        VALUE="$(cat "${!VAR_DOTENV_FILE}")"
    elif [[ -n "${!VAR_DOTENV:-}" ]]; then
        VALUE="${!VAR_DOTENV}"
    fi

    export "${VAR}=${VALUE}"
}

########################################
# Get RCLONE_REMOTE_LIST variables.
# Arguments:
#     None
# Outputs:
#     variable value
########################################
function get_rclone_remote_list() {
    # RCLONE_REMOTE_LIST
    RCLONE_REMOTE_LIST=()

    local i=0
    local RCLONE_REMOTE_NAME_X_REFER
    local RCLONE_REMOTE_DIR_X_REFER
    local RCLONE_REMOTE_X

    # for multiple
    while true; do
        RCLONE_REMOTE_NAME_X_REFER="RCLONE_REMOTE_NAME_${i}"
        RCLONE_REMOTE_DIR_X_REFER="RCLONE_REMOTE_DIR_${i}"
        get_env "${RCLONE_REMOTE_NAME_X_REFER}"
        get_env "${RCLONE_REMOTE_DIR_X_REFER}"

        if [[ -z "${!RCLONE_REMOTE_NAME_X_REFER}" || -z "${!RCLONE_REMOTE_DIR_X_REFER}" ]]; then
            break
        fi

        RCLONE_REMOTE_X=$(echo "${!RCLONE_REMOTE_NAME_X_REFER}:${!RCLONE_REMOTE_DIR_X_REFER}" | sed 's@\(/*\)$@@')
        RCLONE_REMOTE_LIST=(${RCLONE_REMOTE_LIST[@]} "${RCLONE_REMOTE_X}")

        ((i++))
    done
}

########################################
# Initialization environment variables.
# Arguments:
#     None
# Outputs:
#     environment variables
########################################
function init_env() {
    # export
    export_env_file

    init_env_dir
    init_env_db
    init_env_ping
    init_env_mail
    init_env_ntfy

    # CRON
    get_env CRON
    CRON="${CRON:-"5 * * * *"}"

    # RCLONE_REMOTE_NAME
    get_env RCLONE_REMOTE_NAME
    RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-"BitwardenBackup"}"
    RCLONE_REMOTE_NAME_0="${RCLONE_REMOTE_NAME}"

    # RCLONE_REMOTE_DIR
    get_env RCLONE_REMOTE_DIR
    RCLONE_REMOTE_DIR="${RCLONE_REMOTE_DIR:-"/BitwardenBackup/"}"
    RCLONE_REMOTE_DIR_0="${RCLONE_REMOTE_DIR}"

    # get RCLONE_REMOTE_LIST
    get_rclone_remote_list

    # RCLONE_GLOBAL_FLAG
    get_env RCLONE_GLOBAL_FLAG
    RCLONE_GLOBAL_FLAG="${RCLONE_GLOBAL_FLAG:-""}"

    # ZIP_ENABLE
    get_env ZIP_ENABLE
    if [[ "${ZIP_ENABLE^^}" == "FALSE" ]]; then
        ZIP_ENABLE="FALSE"
    else
        ZIP_ENABLE="TRUE"
    fi

    # ZIP_PASSWORD
    get_env ZIP_PASSWORD
    ZIP_PASSWORD="${ZIP_PASSWORD:-"WHEREISMYPASSWORD?"}"

    # ZIP_TYPE
    get_env ZIP_TYPE
    if [[ "${ZIP_TYPE,,}" == "7z" ]]; then
        ZIP_TYPE="7z"
    else
        ZIP_TYPE="zip"
    fi

    # BACKUP_KEEP_DAYS
    get_env BACKUP_KEEP_DAYS
    BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-"0"}"

    # BACKUP_FILE_DATE_FORMAT
    get_env BACKUP_FILE_SUFFIX
    get_env BACKUP_FILE_DATE
    get_env BACKUP_FILE_DATE_SUFFIX
    BACKUP_FILE_DATE="$(echo "${BACKUP_FILE_DATE:-"%Y%m%d"}${BACKUP_FILE_DATE_SUFFIX}" | sed 's/[^0-9a-zA-Z%_-]//g')"
    BACKUP_FILE_DATE_FORMAT="$(echo "${BACKUP_FILE_SUFFIX:-"${BACKUP_FILE_DATE}"}" | sed 's/\///g')"

    # TIMEZONE
    get_env TIMEZONE
    local TIMEZONE_MATCHED_COUNT=$(ls "/usr/share/zoneinfo/${TIMEZONE}" 2> /dev/null | wc -l)
    if [[ "${TIMEZONE_MATCHED_COUNT}" -ne 1 ]]; then
        TIMEZONE="UTC"
    fi

    color yellow "========================================"
    color yellow "DATA_DIR: ${DATA_DIR}"
    color yellow "DATA_CONFIG: ${DATA_CONFIG}"
    color yellow "DATA_RSAKEY: ${DATA_RSAKEY}"
    color yellow "DATA_ATTACHMENTS: ${DATA_ATTACHMENTS}"
    color yellow "DATA_SENDS: ${DATA_SENDS}"
    color yellow "========================================"
    color yellow "DB_TYPE: ${DB_TYPE}"

    if [[ "${DB_TYPE}" == "POSTGRESQL" ]]; then
        color yellow "DB_URL: postgresql://${PG_USERNAME}:***(${#PG_PASSWORD} Chars)@${PG_HOST}:${PG_PORT}/${PG_DBNAME}"
    elif [[ "${DB_TYPE}" == "MYSQL" ]]; then
        color yellow "DB_URL: mysql://${MYSQL_USERNAME}:***(${#MYSQL_PASSWORD} Chars)@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}"
    else
        color yellow "DATA_DB: ${DATA_DB}"
    fi

    color yellow "========================================"
    color yellow "CRON: ${CRON}"

    for RCLONE_REMOTE_X in "${RCLONE_REMOTE_LIST[@]}"
    do
        color yellow "RCLONE_REMOTE: ${RCLONE_REMOTE_X}"
    done

    color yellow "RCLONE_GLOBAL_FLAG: ${RCLONE_GLOBAL_FLAG}"
    color yellow "ZIP_ENABLE: ${ZIP_ENABLE}"
    color yellow "ZIP_PASSWORD: ${#ZIP_PASSWORD} Chars"
    color yellow "ZIP_TYPE: ${ZIP_TYPE}"
    color yellow "BACKUP_FILE_DATE_FORMAT: ${BACKUP_FILE_DATE_FORMAT} (example \"[filename].$(date +"${BACKUP_FILE_DATE_FORMAT}").[ext]\")"
    color yellow "BACKUP_KEEP_DAYS: ${BACKUP_KEEP_DAYS}"
    if [[ -n "${PING_URL}" ]]; then
        color yellow "PING_URL: ${PING_URL}"
    fi
    if [[ -n "${PING_URL_WHEN_START}" ]]; then
        color yellow "PING_URL_WHEN_START: ${PING_URL_WHEN_START}"
    fi
    if [[ -n "${PING_URL_WHEN_SUCCESS}" ]]; then
        color yellow "PING_URL_WHEN_SUCCESS: ${PING_URL_WHEN_SUCCESS}"
    fi
    if [[ -n "${PING_URL_WHEN_FAILURE}" ]]; then
        color yellow "PING_URL_WHEN_FAILURE: ${PING_URL_WHEN_FAILURE}"
    fi
    color yellow "MAIL_SMTP_ENABLE: ${MAIL_SMTP_ENABLE}"
    if [[ "${MAIL_SMTP_ENABLE}" == "TRUE" ]]; then
        color yellow "MAIL_TO: ${MAIL_TO}"
        color yellow "MAIL_WHEN_SUCCESS: ${MAIL_WHEN_SUCCESS}"
        color yellow "MAIL_WHEN_FAILURE: ${MAIL_WHEN_FAILURE}"
    fi
    color yellow "TIMEZONE: ${TIMEZONE}"
    color yellow "========================================"

    color yellow "NTFY_ENABLE: ${NTFY_ENABLE}"
    color yellow "NTFY_SERVER: ${NTFY_SERVER}"
    color yellow "NTFY_TOPIC: ${NTFY_TOPIC}"
    color yellow "NTFY_USERNAME: ${NTFY_USERNAME}"
    color yellow "NTFY_PASSWORD: ${#NTFY_PASSWORD} Chars"
    color yellow "NTFY_TOKEN: ${#NTFY_TOKEN} Chars"
    color yellow "NTFY_PRIORITY_SUCCESS: ${NTFY_PRIORITY_SUCCESS}"
    color yellow "NTFY_PRIORITY_FAILURE: ${NTFY_PRIORITY_FAILURE}"
    color yellow "NTFY_WHEN_SUCCESS: ${NTFY_WHEN_SUCCESS}"
    color yellow "NTFY_WHEN_FAILURE: ${NTFY_WHEN_FAILURE}"

    color yellow "========================================"
}

function init_env_dir() {
    # DATA_DIR
    get_env DATA_DIR
    DATA_DIR="${DATA_DIR:-"/bitwarden/data"}"
    check_dir_exist "${DATA_DIR}"

    # DATA_DB
    get_env DATA_DB
    DATA_DB="${DATA_DB:-"${DATA_DIR}/db.sqlite3"}"

    # DATA_CONFIG
    DATA_CONFIG="${DATA_DIR}/config.json"

    # DATA_RSAKEY
    get_env DATA_RSAKEY
    DATA_RSAKEY="${DATA_RSAKEY:-"${DATA_DIR}/rsa_key"}"
    DATA_RSAKEY_DIRNAME="$(dirname "${DATA_RSAKEY}")"
    DATA_RSAKEY_BASENAME="$(basename "${DATA_RSAKEY}")"

    # DATA_ATTACHMENTS
    get_env DATA_ATTACHMENTS
    DATA_ATTACHMENTS="$(dirname "${DATA_ATTACHMENTS:-"${DATA_DIR}/attachments"}/useless")"
    DATA_ATTACHMENTS_DIRNAME="$(dirname "${DATA_ATTACHMENTS}")"
    DATA_ATTACHMENTS_BASENAME="$(basename "${DATA_ATTACHMENTS}")"

    # DATA_SEND
    get_env DATA_SENDS
    DATA_SENDS="$(dirname "${DATA_SENDS:-"${DATA_DIR}/sends"}/useless")"
    DATA_SENDS_DIRNAME="$(dirname "${DATA_SENDS}")"
    DATA_SENDS_BASENAME="$(basename "${DATA_SENDS}")"
}

function init_env_db() {
    # DB_TYPE
    get_env DB_TYPE

    if [[ "${DB_TYPE^^}" == "POSTGRESQL" ]]; then # postgresql
        DB_TYPE="POSTGRESQL"

        # PG_HOST
        get_env PG_HOST

        # PG_PORT
        get_env PG_PORT
        PG_PORT="${PG_PORT:-"5432"}"

        # PG_DBNAME
        get_env PG_DBNAME
        PG_DBNAME="${PG_DBNAME:-"vaultwarden"}"

        # PG_USERNAME
        get_env PG_USERNAME
        PG_USERNAME="${PG_USERNAME:-"vaultwarden"}"

        # PG_PASSWORD
        get_env PG_PASSWORD
    elif [[ "${DB_TYPE^^}" == "MYSQL" ]]; then # mysql
        DB_TYPE="MYSQL"

        # MYSQL_HOST
        get_env MYSQL_HOST

        # MYSQL_PORT
        get_env MYSQL_PORT
        MYSQL_PORT="${MYSQL_PORT:-"3306"}"

        # MYSQL_DATABASE
        get_env MYSQL_DATABASE
        MYSQL_DATABASE="${MYSQL_DATABASE:-"vaultwarden"}"

        # MYSQL_USERNAME
        get_env MYSQL_USERNAME
        MYSQL_USERNAME="${MYSQL_USERNAME:-"vaultwarden"}"

        # MYSQL_PASSWORD
        get_env MYSQL_PASSWORD
    else # sqlite
        DB_TYPE="SQLITE"
    fi
}

function init_env_ping() {
    # PING_URL
    get_env PING_URL
    PING_URL="${PING_URL:-""}"

    # PING_URL_WHEN_START
    get_env PING_URL_WHEN_START
    PING_URL_WHEN_START="${PING_URL_WHEN_START:-""}"

    # PING_URL_WHEN_SUCCESS
    get_env PING_URL_WHEN_SUCCESS
    PING_URL_WHEN_SUCCESS="${PING_URL_WHEN_SUCCESS:-""}"

    # PING_URL_WHEN_FAILURE
    get_env PING_URL_WHEN_FAILURE
    PING_URL_WHEN_FAILURE="${PING_URL_WHEN_FAILURE:-""}"
}

function init_env_mail() {
    # MAIL_SMTP_ENABLE
    # MAIL_TO
    get_env MAIL_SMTP_ENABLE
    get_env MAIL_TO
    if [[ "${MAIL_SMTP_ENABLE^^}" == "TRUE" && "${MAIL_TO}" ]]; then
        MAIL_SMTP_ENABLE="TRUE"
    else
        MAIL_SMTP_ENABLE="FALSE"
    fi

    # MAIL_SMTP_VARIABLES
    get_env MAIL_SMTP_VARIABLES
    MAIL_SMTP_VARIABLES="${MAIL_SMTP_VARIABLES:-""}"

    # MAIL_WHEN_SUCCESS
    get_env MAIL_WHEN_SUCCESS
    if [[ "${MAIL_WHEN_SUCCESS^^}" == "FALSE" ]]; then
        MAIL_WHEN_SUCCESS="FALSE"
    else
        MAIL_WHEN_SUCCESS="TRUE"
    fi

    # MAIL_WHEN_FAILURE
    get_env MAIL_WHEN_FAILURE
    if [[ "${MAIL_WHEN_FAILURE^^}" == "FALSE" ]]; then
        MAIL_WHEN_FAILURE="FALSE"
    else
        MAIL_WHEN_FAILURE="TRUE"
    fi
}


function init_env_ntfy() {
    # NTFY_ENABLE
    # NTFY_SERVER
    get_env NTFY_ENABLE
    if [[ "${NTFY_ENABLE^^}" == "TRUE" ]]; then
        NTFY_ENABLE="TRUE"
    else
        NTFY_ENABLE="FALSE"
    fi

    # NTFY_SERVER
    get_env NTFY_SERVER
    NTFY_SERVER="${NTFY_SERVER:-""}"

    # NTFY_TOPIC
    get_env NTFY_TOPIC
    NTFY_TOPIC="${NTFY_TOPIC:-"vaultwarden-backup"}"

    # NTFY_USERNAME
    get_env NTFY_USERNAME
    NTFY_USERNAME="${NTFY_USERNAME:-""}"

    # NTFY_PASSWORD
    get_env NTFY_PASSWORD
    NTFY_PASSWORD="${NTFY_PASSWORD:-""}"

    # NTFY_TOKEN
    get_env NTFY_TOKEN
    NTFY_TOKEN="${NTFY_TOKEN:-""}"
    
     # NTFY_TOKEN
    get_env NTFY_TOKEN
    NTFY_TOKEN="${NTFY_TOKEN:-""}"

     # NTFY_PRIORITY_SUCCESS
    get_env NTFY_PRIORITY_SUCCESS
    NTFY_PRIORITY_SUCCESS="${NTFY_PRIORITY_SUCCESS:-"3"}"


    # NTFY_PRIORITY_FAILURE
    get_env NTFY_PRIORITY_FAILURE
    NTFY_PRIORITY_FAILURE="${NTFY_PRIORITY_FAILURE:-"5"}"  

    # NTFY_WHEN_SUCCESS
    get_env NTFY_WHEN_SUCCESS
    if [[ "${NTFY_WHEN_SUCCESS^^}" == "FALSE" ]]; then
        NTFY_WHEN_SUCCESS="FALSE"
    else
        NTFY_WHEN_SUCCESS="TRUE"
    fi

    # NTFY_WHEN_FAILURE
    get_env NTFY_WHEN_FAILURE
    if [[ "${NTFY_WHEN_FAILURE^^}" == "FALSE" ]]; then
        NTFY_WHEN_FAILURE="FALSE"
    else
        NTFY_WHEN_FAILURE="TRUE"
    fi
}
