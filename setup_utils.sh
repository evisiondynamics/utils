#!/usr/bin/env bash
#
# Script to check/setup/authenticated common system tools: git, gh, docker, rclone, jq, yq, ffmpeg
#
# ./setup_utils.sh        - checks all tools if installed and authenticated
# ./setup_utils.sh <name> - install and authenticate a tool

set -o nounset

function main {
    # install single tool
    local tool="${1:-}"
    local version="${2:-}"
    local token="${3:-}"

    if [[ -n "$tool" ]]; then
        install_tool "$tool" "$version" "$token"
        return $?
    fi

    # check all tools
    local u="\033[4m"
    local n="\033[0m"
    printf "${u}%10s${n}  ${u}%7s${n}  ${u}%s${n}\n" "Name" "Version" "Logged in"

    local status=0
    check_tool git            ;status=$((status + $?))
    check_tool gh             ;status=$((status + $?))
    check_tool jq             ;status=$((status + $?))
    check_tool yq 4.44.3      ;status=$((status + $?))
    check_tool docker 27.3.0  ;status=$((status + $?))
    check_tool rclone         ;status=$((status + $?))
    check_tool ffmpeg         ;status=$((status + $?))

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
        icon="⚠️"
    elif [[ "${level?}" == "error" ]]; then
        icon="❌"
    fi
    printf "%s %7s  %7s  %s\n" "$icon" "$tool" "$version" "$msg"
}


# install and authenticate tool
function install_tool {
    local tool="${1?Name of the tool is required as the first argument}"
    local version="${2:-}"
    local token="${3:-}"
    local os="$(uname)"
    local curr_version

    local check_msg
    local check_status
    check_msg=$(check_tool "$tool" "$version")
    check_status=$?

    case "$check_status" in
        0)  curr_version=$(echo "$check_msg" | cut -d ' ' -f3)
            if [[ -n $version ]]; then
                echo "$tool v$curr_version is already installed and meets the requested version v$version"
            else
                echo "$tool is already installed"
            fi
            return 1
            ;;
        1)  ;;  # not installed, proceed with installation
        2)  echo "Failed to parse version '$tool --version'. Uninstall $tool manually and re-run setup"
            return 2
            ;;
        3)  curr_version=$(echo "$check_msg" | cut -d ' ' -f3)
            echo "$tool version v$curr_version is lower than required v$version. Uninstall $tool manually and re-run setup"
            return 3
            ;;
        4)  echo "$tool is installed, but not authenticated. Proceeding with authentication..."
            local auth_status
            if [[ $check_msg != *"-"* && $(type -t "auth_${tool}") == "function" ]]; then
                eval "auth_${tool} $token"
                auth_status=$?
            fi
            return $auth_status
            ;;
        *)
            echo "Unknown check status ($check_status) for $tool"
            ;;
    esac

    echo -e "\nInstalling $tool..."

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
        mkdir -p ~/.local/bin
        local url="https://github.com/mikefarah/yq/releases/download/v${version}/yq_linux_amd64"
        echo "Downaloding $url"
        curl --show-error --fail --output ~/.local/bin/yq --location "$url"
        [[ $? -ne 0 ]] && exit 1
        chmod +x ~/.local/bin/yq

        if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
            echo "export PATH=\$PATH:$HOME/.local/bin" >> ~/.bashrc
        fi
        return 0
    fi

    case "$os" in
        Linux*)
            # check if update cache was last updated more then 24h ago
            local update_stamp=/var/cache/apt/pkgcache.bin
            if [[ $(find "$update_stamp" -mmin +1140 -print -quit | wc -l) -ne 0 ]]; then
                echo "Update apt cache.."
                sudo apt-get update --yes --quiet
                echo ""
            fi
            version=${version:+=$version}  # replace with "=$version" if $version defined
            sudo apt-get install --upgrade --yes --quiet "$tool$version"
            [[ $? -ne 0 ]] && exit 2
            [[ -n "$version" ]] && sudo apt-mark hold "$tool"
            ;;
        Darwin*)
            version=${version:+=$version}  # replace with "@$version" if $version defined
            brew install "$tool$version"
            [[ -n "$version" ]] && brew pin "$tool"
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
    local version_cmd="${tool} ${dashes}version 2>&1 | head -1"

    local version_raw="$(eval "$version_cmd")"
    local version=$(echo "$version_raw" | sed -E -n "s|[^0-9]*([0-9.]*).*|\1|pi")
    [[ -n ${DEBUG:-} ]] && echo "version raw: $version_raw"

    if [[ "$version" =~ ^[0-9.]+$ ]]; then
        echo "$version"
    else
        echo "  error: cannot parse '${version_cmd/?|*}' output: '$version_raw'"
    fi
}


# check if tool is installed, verify version and authentication status
function check_tool {
    local tool="${1?Name of the tool is required as the first argument}"
    local version_required="${2:-}"  # required version (optional)

    if ! command_exists "$tool"; then
        log error "$tool" " Not installed. Run: ${0} $tool $version_required"
        return 1
    fi

    local version="$(parse_version "$tool")"
    if [[ ! "$version" =~ ^[0-9.]+$ ]]; then
        log error "$tool" "$version"
        return 2
    fi

    if ! version_lte "${version_required:-0.0.0}" "$version"; then
        log warning "$tool" "$version" "required v$version_required. Run: ${0} $tool $version_required"
        return 3
    fi

    local auth_msg
    auth_msg=$(check_auth "$tool")
    if [[ $? -ne 0 ]]; then
        log "warning" "$tool" "$version" "$auth_msg"
        return 4
    fi

    log "success" "$tool" "$version" "$auth_msg"
}


# check if tool is authenticated
function check_auth {
    local tool="${1?Name of the tool is required as the first argument}"

    case "$tool" in
        git)
            domain="github.com"
            auth_check_command="ssh -T git@github.com 2>&1 | grep -iq successfully"
            ;;
        gh)
            domain="github.com"
            auth_check_command="gh auth status >& /dev/null"
            ;;
        docker)
            domain="ghcr.io"
            auth_check_command="docker login $domain <&- 2>&1 | grep -iq succeeded"
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
        message="$tool is not authenticated to $domain. Run: ${0} $tool";
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
    if gh auth status >& /dev/null; then
        : # add ssh key via gh
    else
        echo "Paste key manually at github.com/settings/ssh/new and save it"
        echo "Re-run setup again"
    fi
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
