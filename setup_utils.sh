#!/usr/bin/env bash
#
# Script to check/setup/authenticate common system tools: git, gh, dvc, docker, rclone, jq, yq, ffmpeg
#
# Command line args:
# <_>    - if no args provided, check each tool if it is installed and authenticated
# <name> - install and authenticate a tool by its name

set -o nounset

function main {
    [[ ! $(uname) =~ Linux|Darwin ]] && { echo "$(uname) is not supported"; exit 1; }

    check_quartz

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
    check_tool gh 2.63.1      ;status=$((status + $?))
    check_tool git            ;status=$((status + $?))
    check_tool jq             ;status=$((status + $?))
    check_tool yq 4.44.3      ;status=$((status + $?))
    check_tool docker 27.3.0  ;status=$((status + $?))
    check_tool dvc            ;status=$((status + $?))
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


# install and authenticate tool
function install_tool {
    local tool="${1?Name of the tool is required as the first argument}"
    local version="${2:-}"
    local token="${3:-}"
    local os="$(uname)"

    local check_msg
    local check_status
    check_msg=$(check_tool "$tool" "$version")
    check_status=$?

    [[ -n ${DEBUG:-} ]] && echo "install check_msg: '$check_msg'"

    local curr_version=$(echo "$check_msg" | tr -s ' ' | cut -d ' ' -f3)
    case "$check_status" in
        0)  if [[ -n $version ]]; then
                echo "$tool v$curr_version is already installed and meets the requested version v$version"
            else
                echo "$tool v$curr_version is already installed"
            fi
            # return $check_status
            ;;
        1)  ;;  # not installed, proceed with installation
        2)  echo "Failed to parse version '$tool --version'. Uninstall $tool manually and re-run setup"
            return $check_status
            ;;
        3)  echo "$tool version v$curr_version is lower than required v$version. Uninstall $tool manually and re-run setup"
            return $check_status
            ;;
        4)  echo -e "$tool is installed, but not authenticated. Proceeding with authentication...\n"
            local auth_status
            if [[ $check_msg != "-" && $(type -t "auth_${tool}") == "function" ]]; then
                eval "auth_${tool} $token"
                auth_status=$?
            fi
            return $auth_status
            ;;
        *)  echo "Unexpected check status ($check_status) for $tool"
            return 100
            ;;
    esac

    echo -e "\nInstalling $tool..."

    # special case for docker
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

    # special case for gh
    if [[ $tool == "gh" && $os == "Linux" ]]; then
        # source: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
        sudo mkdir -p -m 755 /etc/apt/keyrings
        wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
            sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        local gh_deb="arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg"
        echo "deb [$gh_deb] https://cli.github.com/packages stable main" | \
            sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt update --yes --quiet
    fi

    # special case for yq
    if [[ $tool == "yq" && $os == "Linux" ]]; then
        mkdir -p ~/.local/bin
        if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
            echo "export PATH=\$PATH:$HOME/.local/bin" >> ~/.bashrc
        fi

        local url="https://github.com/mikefarah/yq/releases/download/v${version}/yq_linux_amd64"
        echo "Downloading $url"
        curl --show-error --fail --output ~/.local/bin/yq --location "$url"
        [[ $? -ne 0 ]] && exit 2
        chmod +x ~/.local/bin/tq
        return 0
    fi

    # special case for dvc
    if [[ $tool == "dvc" && $os == "Linux" ]] && ! apt-cache show dvc &>/dev/null; then
        # source: https://dvc.org/doc/install/linux
        sudo wget https://dvc.org/deb/dvc.list -O /etc/apt/sources.list.d/dvc.list
        wget -qO - https://dvc.org/deb/iterative.asc | gpg --dearmor > packages.iterative.gpg
        sudo install -o root -g root -m 644 packages.iterative.gpg /etc/apt/trusted.gpg.d/
        rm -f packages.iterative.gpg
        sudo apt update --yes --quiet
    fi

    case "$os" in
        Linux*)
            # update cache only if the last update was more than 24h ago
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
            brew install "$tool$version"  # WARNING: brew does not keep older releases
            [[ -n "$version" ]] && brew pin "$tool"
            ;;

        *) echo "$os not supported. For Windows, setup WSL/Ubuntu and run ${0} there" ;;
    esac

    if [[ $(type -t "auth_${tool}") == "function" ]]; then
        eval "auth_${tool} $token"
    fi
}


function parse_version {
    # universal parser for any `command --version` output
    # parses version number [0-9].[0-9].[0-9] in the first line of the output of `--version` run
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


# check if tool is authenticated
function check_auth {
    local tool="${1?Name of the tool is required as the first argument}"

    case "$tool" in
        git)
            domain="github.com"
            auth_check_command="ssh -T git@$domain 2>&1 | grep -i -q successfully"
            ;;
        gh)
            domain="github.com"
            auth_check_command="gh auth status >& /dev/null"
            ;;
        docker)
            domain="ghcr.io"
            auth_check_command="docker login $domain <&- 2>&1 | grep -i -q succeeded"
            ;;
        dvc)
            client_id=$( [[ -f .dvc/config ]] && echo $(dvc config remote.gdrive.gdrive_client_id) || echo "*.apps.googleusercontent.com" )
            cache_dir=$( [[ $(uname) == "Darwin" ]] && echo "$HOME/Library/Caches" || echo "$HOME/.cache" )
            domain="google.com/drive"
            auth_check_command="grep -Es -q '\"access_token\": \"\S+\"' ${cache_dir}/pydrive2fs/${client_id}/default.json"
            ;;
        rclone)
            domain="google.com/drive"
            auth_check_command="rclone config show eagledrive | grep -i -q '^token = '"
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

    [[ -n ${DEBUG:-} ]] && echo -e "\nauth check command: '${auth_check_command//-q}'\nauth check output: '$(eval "${auth_check_command//-q}")'"

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


function check_quartz {
    if [[ "$(uname)" != "Darwin" ]]; then
        return 0
    fi

    if ! brew list xquartz &> /dev/null; then
        echo "XQuartz is required for GUI applications on macOS. Install it manually:"
        echo "brew install --cask xquartz"
        echo ""
        echo "XQuartz notes on first install:"
        echo "- Launch XQuartz. Under the XQuartz menu, select Preferences"
        echo "- Go to the security tab and ensure \"Allow connections from network clients\" is checked."
        exit 1
    fi
}


################################################################################
############################ authentication ####################################
################################################################################

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


function auth_git {
    echo "Generating ssh key pair for github.com"
    ssh-keygen -b 2048 -t rsa -f ~/.ssh/eagle_github -q -N ""
    ls -alF ~/.ssh/eagle_github*
    if gh auth status >& /dev/null; then
        echo "Adding public key to github.com via gh"
        gh ssh-key add --title eagle ~/.ssh/eagle_github.pub
    else
        echo "Copy ~/.ssh/eagle_github.pub key below to clipboard"
        cat ~/.ssh/eagle_github.pub
        echo "Paste the key manually at https://github.com/settings/ssh/new and press Save"
        echo "Re-run setup again"
    fi
}


function auth_docker {
    local token=${1:-}

    auth_msg=$(check_auth docker)
    auth_status=$?
    if [[ $auth_status -eq 0 ]]; then
        echo "docker is authenticated already: $auth_msg"
        if [[ -n "$token" ]]; then
            echo "Provided token is ignored. To use new token, first logout 'docker logout ghcr.io'"
        fi
        return 0
    fi

    if ! gh auth status &> /dev/null; then
        echo "Cannot authenticate docker automatically without 'gh' being authenticated first."
        echo "Possible solutions (choose one):"
        echo "1. Authenticate 'gh' by running '${0} gh', and then re-run '${0} docker'"
        echo "2. Follow docker authentication manual:"
        echo "https://github.com/evisiondynamics/.github-private/blob/main/profile/tools.md#docker-setup"
        return 10
    fi

    local username="$(gh api user | jq -r .login)"

    if [[ -n "$token" ]]; then
        echo "Logining docker to ghcr.io with provided token..."
    else
        echo "Re-using 'gh' token for docker login..."
        token=$(gh auth token)
    fi

    echo "$token" | docker login ghcr.io -u "$username" --password-stdin
    return $?
}


function auth_dvc {
    if [[ ! -f .dvc/config ]]; then
        echo "No .dvc/config found, dvc can be authenticated only within a project where dvc is configured"
        return 1
    fi

    local client_id=$(dvc config remote.gdrive.gdrive_client_id)
    local client_secret=$(dvc config remote.gdrive.gdrive_client_secret)
    if [[ -z $client_id || -z $client_secret ]]; then
        echo "OAuth client creds are missing, they are required for dvc authorization to Google Drive API."
        echo "Contact your cloud administrator, for details visit:"
        echo "https://dvc.org/doc/user-guide/data-management/remote-storage/google-drive#using-a-custom-google-cloud-project-recommended"
        return 2
    fi

    [[ -n ${SSH_CONNECTION:-} ]] && print_ssh_tunnel_message "rclone" 8090
    dvc status --cloud
}


function auth_rclone {
    local target_remote="eagledrive"

    [[ -n ${SSH_CONNECTION:-} ]] && print_ssh_tunnel_message "rclone" 53682
    echo "Logining in rclone to Eagle Google Drive..."
    rclone config create "${target_remote}" drive scope drive.readonly config_refresh_token true
}


function print_ssh_tunnel_message {
    local tool=${1?Tool name is required as the first argument}
    local auth_protocol=${2?Localhost auth protocol is required as the second argument}

    local yellow="\033[0;33m"
    local nc="\033[0m"
    echo -e "\n${yellow}To authenticate ${tool} on remote machine:"
    echo "1. Wait until ${tool} auth url is available below in terminal"
    echo "2. Open ssh tunnel, run this command on your local machine and leave it hanging after password prompt (no output):"
    echo "   ssh -L ${auth_protocol}:localhost:${auth_protocol} -C -N -l ${USER?} <remote_hostname>"
    echo -e "3. Open auth url below in your browser on local machine${nc}\n"
}
################################################################################

main "$@"
