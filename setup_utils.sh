#!/usr/bin/env bash
#
# Script to check/setup/authenticated common system tools: git, gh, docker, rclone, jq, yq, ffmpeg
#
# ./setup_tools.sh        - checks all tools if installed and authenticated
# ./setup_tools.sh <tool> - install and authenticate a tool

set -o nounset

function main {
    # install single tool
    local tool="${1:-}"
    local token="${2:-}"
    if [[ -n "$tool" ]]; then
        install_tool "$tool" "$token"
        return $?
    fi

    # check all tools
    local u="\033[4m"
    local n="\033[0m"
    printf "${u}%10s${n}  ${u}%7s${n}  ${u}%s${n}\n" "Name" "Version" "Logged in"

    local status=0

    check_tool git
    status=$((status + $?))
    check_tool gh 2.50.0
    status=$((status + $?))
    check_tool jq
    status=$((status + $?))
    check_tool yq 4.16.0
    status=$((status + $?))
    check_tool docker 27.3.0
    status=$((status + $?))
    check_tool rclone 1.53.0
    status=$((status + $?))
    check_tool ffmpeg
    status=$((status + $?))

    echo ""
    return $status
}


################################################################################
#################################### Utils #####################################
################################################################################

function command_exists { command -v "${1?}" &> /dev/null; }


function version_lte { [[  "$1" = "$(echo -e "$1\n$2" | sort --version-sort | head --lines=1)" ]]; }


function log
{
    local level=${1?}
    local tool=${2?}
    local version=${3?}
    local msg=${4:-}

    if [[ "${level?}" == "success" ]]; then
        icon="✅"
    elif [[ "${level?}" == "warning" ]]; then
        icon="⚠️ "
    elif [[ "${level?}" == "error" ]]; then
        icon="❌"
    fi
    printf "%s %7s  %7s  %s\n" "$icon" "$tool" "$version" "$msg"
}


# install and authenticate tool
function install_tool {
    local tool="${1?Name of the tool is required as the first argument}"
    local token="${2:-}"
    local os="$(uname)"

    if command_exists "$tool"; then
        echo "$tool is already installed"
        local auth_msg

        auth_msg=$(check_auth "$tool")
        auth_status=$?
        if [[ $auth_status -eq 0 && $auth_msg != "-" ]]; then
            echo "$tool is already authenticated: $auth_msg"
            return 0
        fi

        if [[ $(type -t "auth_${tool}") == "function" ]]; then
            eval "auth_${tool} $token"
        fi

        return 0
    fi

    echo -e "Installing $tool...\n"

    # TODO: docker install script
    if [[ $tool == "docker" ]]; then
        grep -q WSL /proc/version && os="WSL"  # in Windows, docker must be installed on Windows host, not on WSL Ubuntu
        case "$os" in
            Linux*)
                url="https://docs.docker.com/engine/install/ubuntu/" ;;
            Darwin*)
                url="https://docs.docker.com/docker-for-mac/install/" ;;
            WSL*)
                url="https://docs.docker.com/desktop/setup/install/windows-install/" ;;
            *) echo "$os not supported" ;;
        esac
        echo "Install docker manually $url"
        return 0
    fi

    if [[ $tool == "yq" && $os == "Linux" ]]; then
        sudo add-apt-repository --yes --update ppa:rmescandon/yq
    fi

    # TODO: mark/hold the installed package
    case "$os" in
        Linux*)
            # check if update cache was last updated more then 24h ago
            local update_stamp=/var/cache/apt/pkgcache.bin
            if [[ $(find "$update_stamp" -mmin +1140 -print -quit | wc -l) -ne 0 ]]; then
                echo "Update apt cache.."
                sudo apt-get update --yes --quiet
                echo ""
            fi
            sudo apt-get install --upgrade --yes --quiet "$tool"
            ;;
        Darwin*)
            brew install "$tool"
            ;;
        *) echo "$os not supported" ;;
    esac

    if [[ $(type -t "auth_${tool}") == "function" ]]; then
        eval "auth_${tool} $token"
    fi
}


function parse_version {
    local tool="${1?Name of the tool is required as the first argument}"
    if [[ "$tool" == "ffmpeg" ]]; then local dashes="-"; else local dashes="--"; fi
    local version_cmd="${tool} ${dashes}version |& head -1"

    local version_raw="$(eval "$version_cmd")"
    local version=$(echo "$version_raw" | sed -E -n "s|[^0-9]*([0-9.]*).*|\1|pi")
    [[ -n ${DEBUG:-} ]] && echo "version raw: $version_raw"

    if [[ "$version" =~ ^[0-9.]+$ ]]; then
        echo "$version"
    else
        echo "  error: cannot parse '${version_cmd/?|*}' output: '$version_raw'"
    fi
}


# check if tool is installed, its version and authentication status
function check_tool {
    local tool="${1?Name of the tool is required as the first argument}"
    local version_required="${2:-0.0.0}"  # required version (optional)

    if ! command_exists "$tool"; then
        log error "$tool" " Not installed. Run '${0} $tool'"
        return 1
    fi

    local version="$(parse_version "$tool")"
    if [[ ! "$version" =~ ^[0-9.]+$ ]]; then
        log error "$tool" "$version"
        return 2
    fi

    if ! version_lte "$version_required" "$version"; then
        log warning "$tool" "$version" "required: $version_required"
        return 3
    fi

    local log_type="success"
    local auth_msg
    auth_msg=$(check_auth "$tool")
    if [[ $? -ne 0 ]]; then
        log_type="warning"
    fi

    log "$log_type" "$tool" "$version" "$auth_msg"
}


# check if tool is authenticated
function check_auth {
    local tool="${1?Name of the tool is required as the first argument}"

    case "$tool" in
        git)
            domain="github.com"
            auth_check_command="ssh -T git@github.com |& grep -iq successfully"
            ;;
        gh)
            domain="github.com"
            auth_check_command="gh auth status >& /dev/null"
            ;;
        docker)
            domain="ghcr.io"
            auth_check_command="docker login $domain <&- |& grep -iq succeeded"
            ;;
        rclone)
            domain="google.com/drive"
            auth_check_command="rclone config show eagledrive >& /dev/null"
            ;;
        ffmpeg)
            domain="-"
            auth_check_command=""
            ;;
        yq)
            domain="-"
            auth_check_command=""
            ;;
        jq)
            domain="-"
            auth_check_command=""
            ;;
        *) echo "Authentication check not implemented for $tool"
           return 0
           ;;
    esac

    eval "$auth_check_command"
    auth_status=$?
    if [[ $auth_status -eq 0 ]]; then
        message="$domain";
    else
        message="$tool is not authenticated to $domain. Run 'setup_tools.sh $tool'";
    fi
    echo "$message"
    return $auth_status
}


################################################################################
########################### authenticattion ####################################
################################################################################


function auth_git {
    echo "Generating ssh key pair for github.com"
    ssh-keygen -b 2048 -t rsa -f ~/.ssh/eagle_github -q -N ""
    echo "Copy ~/.ssh/eagle_github.pub key below to clipboard"
    cat ~/.ssh/eagle_github.pub
    echo "Paste key value at github.com/settings/ssh/new and save it"
    echo "Re-run setup again"
}


function auth_gh {
    local token=${1:-}

    if [[ -n "$token" ]]; then
        echo "Logining in gh to github.com with token..."
        gh auth login --with-token <<< "$token"
        return $?
    fi

    echo "Logining in gh to github.com interactively via browser"
    gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web
}


function auth_docker {
    local token=${1:-}

    if ! gh auth status &> /dev/null; then
        echo "gh is not authenticated. Authenticate gh first '${0} gh', then re-run '${0} docker'."
        echo "Or authenticate docker manually:"
        echo "https://github.com/evisiondynamics/.github-private/blob/main/profile/tools.md#docker-setup"
        return 1
    fi

    local username="$(gh api user | jq -r .login)"

    auth_msg=$(check_auth docker)
    auth_status=$?
    if [[ $auth_status -eq 0 ]]; then
        echo "docker is authenticated already: $auth_msg"
        if [[ -n "$token" ]]; then
            echo "Provided token is ignored. To use new token, first logout 'docker logout ghcr.io'"
        fi
        return 0
    fi

    if [[ -n "$token" ]]; then
        echo "Logining in docker to ghcr.io via token..."
        echo "$token" | docker login ghcr.io -u "$username" --password-stdin
        return $?
    fi

    echo "Logining in docker to ghcr.io is possible via tokens only."
    echo "Generate a token at https://github.com/settings/tokens/new?scopes=write:packages"
    echo "Then run '${0} docker <token>'"
    return 0
}


function auth_rclone {
    local target_remote="eagledrive"
    echo "Logining in rclone to Eagle Google Drive..."
    rclone config create "${target_remote}" drive scope drive.readonly config_refresh_token true
}

################################################################################

main "$@"
