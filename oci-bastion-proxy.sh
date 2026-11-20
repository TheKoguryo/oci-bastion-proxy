#!/usr/bin/env bash
# Requires configured OCI CLI and OpenSSH. Compatible with macOS Bash 3.2.
set -euo pipefail

# --- Configuration (edit these values directly) ---
# Keep these arrays in the same order. Add other region/Bastion pairs as needed.
REGIONS=("ap-chuncheon-1" "ap-seoul-1")
BASTION_OCIDS=(
    "ocid1.bastion.oc1.ap-chuncheon-1.REPLACE_WITH_YOUR_BASTION_ID"
    "ocid1.bastion.oc1.ap-seoul-1.REPLACE_WITH_YOUR_BASTION_ID"
)
PUBLIC_KEY_PATH="$HOME/.ssh/ssh-key-2026-11-19.key.pub"
PRIVATE_KEY_PATH="$HOME/.ssh/ssh-key-2026-11-19.key"
PROFILE_NAME="${OCI_CLI_PROFILE:-DEFAULT}"
SESSION_TTL_SECONDS=10800
LOCAL_PORT=1080
MAX_WAIT_SECONDS=120
# --- End Configuration ---

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: bash bastion_dynamic_port_forwarding.sh [--region REGION] [--local-port PORT] [--print-only]

Reuses or creates an OCI Bastion Dynamic Port Forwarding session and starts a SOCKS5
tunnel at 127.0.0.1:1080. Press Ctrl+C to stop the tunnel.
Select a region from the menu, or supply --region to skip the menu.

  --region REGION    Region to connect to (must be configured in REGIONS)
  --local-port PORT  Local SOCKS5 port (default: configured LOCAL_PORT, 1080)
  --print-only       Reuse/create a session and print its command without running SSH
  -h, --help         Show this help

Configuration: edit the values at the top of this script:
REGIONS, BASTION_OCIDS, PUBLIC_KEY_PATH, PRIVATE_KEY_PATH, PROFILE_NAME,
SESSION_TTL_SECONDS, LOCAL_PORT, MAX_WAIT_SECONDS.
OCI_CLI_PROFILE selects the OCI profile; if unset or empty, DEFAULT is used.
Other script settings are not read from environment variables.
No separate Python environment or jq is required.
EOF
}

print_only=false
selected_region=
while (($#)); do
    case $1 in
        --region)
            (($# >= 2)) || die '--region requires a value.'
            selected_region=$2; shift 2 ;;
        --local-port)
            (($# >= 2)) || die '--local-port requires a value.'
            LOCAL_PORT=$2; shift 2 ;;
        --print-only) print_only=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

[[ ${#REGIONS[@]} -eq ${#BASTION_OCIDS[@]} && ${#REGIONS[@]} -gt 0 ]] ||
    die 'Configure one Bastion OCID entry for each region.'

if [[ -z $selected_region ]]; then
    printf 'Select a region:\n' >&2
    for ((i=0; i<${#REGIONS[@]}; i++)); do
        label=${REGIONS[i]}
        if [[ -z ${BASTION_OCIDS[i]} ]]; then
            label+=' (Bastion OCID not configured)'
        fi
        printf '  %d) %s\n' "$((i + 1))" "$label" >&2
    done
    while :; do
        printf 'Enter a number (1-%d): ' "${#REGIONS[@]}" >&2
        IFS= read -r choice || die 'Region selection cancelled.'
        if [[ $choice =~ ^[0-9]{1,5}$ ]]; then
            choice=$((10#$choice))
            if ((choice >= 1 && choice <= ${#REGIONS[@]})); then
                selected_region=${REGIONS[choice-1]}
                break
            fi
        fi
        printf 'Invalid selection. Please enter a listed number.\n' >&2
    done
fi

region_found=false
for ((i=0; i<${#REGIONS[@]}; i++)); do
    if [[ ${REGIONS[i]} == "$selected_region" ]]; then
        region_found=true
        BASTION_OCID=${BASTION_OCIDS[i]}
        break
    fi
done
$region_found || die "Region is not configured: $selected_region"
[[ -n $BASTION_OCID ]] || die "Set the Bastion OCID for $selected_region in BASTION_OCIDS."
[[ $BASTION_OCID == ocid1.bastion.*."$selected_region".* ]] ||
    die "Bastion OCID does not match selected region $selected_region: $BASTION_OCID"
printf 'Selected region: %s\nBastion: %s\n' "$selected_region" "$BASTION_OCID" >&2

[[ $LOCAL_PORT =~ ^[0-9]{1,5}$ ]] || die 'Local port must be between 1 and 65535.'
LOCAL_PORT=$((10#$LOCAL_PORT))
((LOCAL_PORT >= 1 && LOCAL_PORT <= 65535)) || die 'Local port must be between 1 and 65535.'
[[ $SESSION_TTL_SECONDS =~ ^[0-9]{1,5}$ ]] || die 'Invalid session TTL.'
SESSION_TTL_SECONDS=$((10#$SESSION_TTL_SECONDS))
((SESSION_TTL_SECONDS >= 1800 && SESSION_TTL_SECONDS <= 10800)) || die 'Session TTL must be 1800–10800 seconds (and within the Bastion maximum).'
[[ $MAX_WAIT_SECONDS =~ ^[0-9]{1,5}$ ]] || die 'Invalid maximum wait time.'
MAX_WAIT_SECONDS=$((10#$MAX_WAIT_SECONDS))
((MAX_WAIT_SECONDS > 0)) || die 'Maximum wait time must be positive.'

command -v oci >/dev/null 2>&1 || die 'OCI CLI is not installed or is not on PATH.'
if ! $print_only; then
    command -v ssh >/dev/null 2>&1 || die 'OpenSSH is not installed or is not on PATH.'
    [[ -r $PRIVATE_KEY_PATH ]] || die "Cannot read private key: $PRIVATE_KEY_PATH"
fi
[[ -r $PUBLIC_KEY_PATH ]] || die "Cannot read public key: $PUBLIC_KEY_PATH"

# Only the OpenSSH key type and base64 data are sent, omitting the comment.
# Restrict their alphabet so the JSON can be built without a JSON utility.
key_type= key_data= key_comment=
IFS=$' \t' read -r key_type key_data key_comment < "$PUBLIC_KEY_PATH" || true
[[ $key_type =~ ^[a-zA-Z0-9@._+-]+$ && $key_data =~ ^[a-zA-Z0-9+/=]+$ ]] ||
    die 'Public key must contain an OpenSSH key type and base64 key data.'
printf -v key_details '{"publicKeyContent":"%s %s"}' "$key_type" "$key_data"

oci_cli() { oci --profile "$PROFILE_NAME" --region "$selected_region" --output json "$@"; }
trap 'printf "\nInterrupted. Any created OCI session remains until expiry or deletion.\n" >&2; exit 130' INT

printf 'Checking for active Dynamic Port Forwarding sessions...\n' >&2
# Filter by type before fetching key details. --all includes every results page.
# join returns a plain string so no JSON parser is needed, even for an empty list.
candidate_ids=$(oci_cli bastion session list \
    --bastion-id "$BASTION_OCID" --session-lifecycle-state ACTIVE --all \
    --sort-by timeCreated --sort-order DESC \
    --query "join(' ', data[?\"target-resource-details\".\"session-type\" == 'DYNAMIC_PORT_FORWARDING'].id || \`[]\`)" \
    --raw-output)
session_id=
while IFS= read -r candidate_id; do
    [[ -n $candidate_id ]] || continue
    [[ $candidate_id == ocid1.bastionsession.* ]] || die "Unexpected session ID in list: $candidate_id"
    candidate_key=$(oci_cli bastion session get --session-id "$candidate_id" \
        --query 'data."key-details"."public-key-content"' --raw-output)
    candidate_key_type= candidate_key_data= candidate_key_comment=
    IFS=$' \t' read -r candidate_key_type candidate_key_data candidate_key_comment <<< "$candidate_key" || true
    # Comments do not form part of the key identity.
    if [[ $candidate_key_type == "$key_type" && $candidate_key_data == "$key_data" ]]; then
        session_id=$candidate_id
        printf 'Reusing active session: %s\n' "$session_id" >&2
        break
    fi
done <<< "${candidate_ids// /$'\n'}"

if [[ -z $session_id ]]; then
    printf 'No matching active session found. Creating a Dynamic Port Forwarding session...\n' >&2
    session_id=$(oci_cli bastion session \
        create-session-create-dynamic-port-forwarding-session-target-resource-details \
        --bastion-id "$BASTION_OCID" \
        --display-name dynamic-port-forwarding \
        --key-details "$key_details" \
        --session-ttl-in-seconds "$SESSION_TTL_SECONDS" \
        --query data.id --raw-output)
fi
[[ $session_id == ocid1.bastionsession.* ]] || die 'OCI CLI did not return a valid session ID.'
printf 'Session: %s\nWaiting for ACTIVE...\n' "$session_id" >&2

wait_started=$SECONDS
while :; do
    state=$(oci_cli bastion session get --session-id "$session_id" \
        --query 'data."lifecycle-state"' --raw-output)
    case $state in
        ACTIVE) break ;;
        FAILED|DELETING|DELETED)
            die "Session $session_id entered $state. Inspect it with: oci bastion session get --session-id $session_id" ;;
        CREATING) ;;
        *) die "Unexpected lifecycle state for $session_id: $state" ;;
    esac
    ((SECONDS - wait_started < MAX_WAIT_SECONDS)) || die "Timed out waiting for $session_id. The session may still become active."
    sleep 5
done

ssh_command=$(oci_cli bastion session get --session-id "$session_id" \
    --query 'data."ssh-metadata".command' --raw-output)
[[ -n $ssh_command && $ssh_command != null && $ssh_command != None ]] || die 'No SSH command returned.'

# Tokenize the CLI's SSH template without eval or executing shell expansions.
# Preserve the nested ProxyCommand as one argument, including its inner quotes.
ssh_args=()
token= quote= escaped=false started=false
for ((i=0; i<${#ssh_command}; i++)); do
    char=${ssh_command:i:1}
    if $escaped; then
        # Inside double quotes, backslashes only escape these shell characters.
        if [[ $quote == '"' && $char != '"' && $char != '\' && $char != '$' && $char != '`' ]]; then
            token+='\'
        fi
        token+=$char; escaped=false
    elif [[ $char == '\' && $quote != "'" ]]; then
        escaped=true; started=true
    elif [[ -n $quote ]]; then
        if [[ $char == "$quote" ]]; then quote=; else token+=$char; fi
    else
        case $char in
            "'"|'"') quote=$char; started=true ;;
            ' '|$'\t'|$'\n'|$'\r')
                if $started; then ssh_args+=("$token"); token=; started=false; fi ;;
            *) token+=$char; started=true ;;
        esac
    fi
done
[[ -z $quote && $escaped == false ]] || die 'Unbalanced quoting in SSH metadata.'
if $started; then ssh_args+=("$token"); fi
[[ ${#ssh_args[@]} -gt 0 && ${ssh_args[0]} == ssh ]] || die 'Invalid SSH command in session metadata.'

# Nested ProxyCommand is interpreted by a shell, so quote its key path separately.
quoted_key="'"
for ((j=0; j<${#PRIVATE_KEY_PATH}; j++)); do
    char=${PRIVATE_KEY_PATH:j:1}
    if [[ $char == "'" ]]; then quoted_key+="'\"'\"'"; else quoted_key+=$char; fi
done
quoted_key+="'"
has_dynamic=false
has_no_command=false
for ((i=1; i<${#ssh_args[@]}; i++)); do
    arg=${ssh_args[i]}
    if [[ $arg == '<privateKey>' ]]; then
        arg=$PRIVATE_KEY_PATH
    else
        arg=${arg//<privateKey>/"$quoted_key"}
    fi
    # OCI may already include the loopback address in its template.
    arg=${arg//127.0.0.1:<localPort>/127.0.0.1:$LOCAL_PORT}
    arg=${arg//<localPort>/127.0.0.1:$LOCAL_PORT}
    [[ ! $arg =~ \<[^\>]+\> ]] || die 'Unresolved placeholder in SSH command.'
    [[ $arg != -D ]] || has_dynamic=true
    [[ $arg != -N ]] || has_no_command=true
    ssh_args[i]=$arg
done
$has_dynamic || die 'SSH metadata does not contain a dynamic forwarding option (-D).'
if ! $has_no_command; then ssh_args=(ssh -N "${ssh_args[@]:1}"); fi
ssh_args=(ssh -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 "${ssh_args[@]:1}")

if $print_only; then
    printf '%q ' "${ssh_args[@]}"
    printf '\n'
    exit 0
fi

printf 'Starting SOCKS5 tunnel at 127.0.0.1:%s. Configure your client after SSH connects.\n' "$LOCAL_PORT" >&2
printf 'Keep this terminal open. Press Ctrl+C to stop.\n' >&2
# Replace Bash with SSH, preserving its terminal and exit status.
exec "${ssh_args[@]}"
