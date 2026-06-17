#!/bin/bash

# ---- Config ----
litellm_docker_port=4000
: "${cloudflared_log_level:=info}"       # default log level if not set
max_readiness_retries=30                  # ~60s timeout for readiness check

# ---- Emoji helpers (if not already defined by caller) ----
: "${TOOL:=🔧}"; : "${CROSS:=❌}"; : "${DOWNLOAD:=📥}"
: "${CHECK:=✅}"; : "${GLOBE:=🌍}"; : "${CLOCK:=⏳}"; : "${INFO:=ℹ️}"
: "${BOLD:=}"; : "${RESET:=}"

# ---- Set DNS to Cloudflare 1.1.1.1 (for Ubuntu LTS containers) ----
set_dns() {
    # Check if 1.1.1.1 is already configured
    if grep -q '^nameserver 1\.1\.1\.1$' /etc/resolv.conf 2>/dev/null; then
        echo -e "  ${CHECK} DNS already set to 1.1.1.1"
        return 0
    fi

    echo -e "  ${TOOL} Setting DNS to 1.1.1.1..."

    # Method 1: systemd-resolved (modern Ubuntu)
    if command -v resolvectl &> /dev/null; then
        # Find the default interface
        iface=$(resolvectl status 2>/dev/null | grep -m1 'Link' | awk '{print $2}' | tr -d ':')
        iface="${iface:-$(ip -o route get 1.1.1.1 2>/dev/null | sed 's/.*dev \([^ ]*\).*/\1/')}"
        if [ -n "$iface" ]; then
            sudo resolvectl dns "$iface" 1.1.1.1 2>/dev/null && {
                echo -e "  ${CHECK} DNS set to 1.1.1.1 (via resolvectl)"
                return 0
            }
        fi
    fi

    # Method 2: Direct write (works with special mounts that block sed -i)
    echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null && {
        echo -e "  ${CHECK} DNS set to 1.1.1.1"
        return 0
    }

    echo -e "  ${CROSS} Failed to set DNS"
    return 1
}
set_dns

# ---- Disable IPv6 (container has no IPv6 connectivity) ----
disable_ipv6() {
    if [ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "0" ]; then
        echo -e "  ${TOOL} Disabling IPv6 (not reachable from this container)..."
        echo 1 | sudo tee /proc/sys/net/ipv6/conf/all/disable_ipv6 > /dev/null
        echo 1 | sudo tee /proc/sys/net/ipv6/conf/default/disable_ipv6 > /dev/null
        echo -e "  ${CHECK} IPv6 disabled"
    else
        echo -e "  ${CHECK} IPv6 already disabled"
    fi
}
disable_ipv6

# ---- Ensure tmux is installed ----
install_tmux() {
    echo -e "  ${TOOL} tmux not found — installing..."
    sudo apt-get update -qq && sudo apt-get install -y -qq tmux
    echo -e "  ${CHECK} tmux installed successfully."
}

if command -v tmux &> /dev/null; then
    echo -e "  ${CHECK} tmux is available."
else
    install_tmux
fi

# ---- Kill existing tmux session 'tun' if present ----
if tmux has-session -t tun 2>/dev/null; then
    echo -e "  ${TOOL} Killing existing tmux session 'tun'..."
    tmux kill-session -t tun
    sleep 1
fi

# ---- Install cloudflared if missing ----
install_cloudflared() {
    echo -e "  ${TOOL} cloudflared not found — installing..."
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|arm) arch="arm" ;;
        *) echo -e "  ${CROSS} Unsupported architecture: $arch"; exit 1 ;;
    esac
    case "$os" in
        linux) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" ;;
        darwin) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${arch}" ;;
        *) echo -e "  ${CROSS} Unsupported OS: $os"; exit 1 ;;
    esac
    echo -e "  ${DOWNLOAD} Downloading cloudflared from $url"
    if [ -w /usr/local/bin ]; then
        curl -sL "$url" -o /usr/local/bin/cloudflared
        chmod +x /usr/local/bin/cloudflared
        cloudflared_bin="cloudflared"
    elif command -v sudo &> /dev/null; then
        curl -sL "$url" -o /tmp/cloudflared
        sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
        sudo chmod +x /usr/local/bin/cloudflared
        cloudflared_bin="cloudflared"
    else
        curl -sL "$url" -o ./cloudflared
        chmod +x ./cloudflared
        cloudflared_bin="./cloudflared"
    fi
    echo -e "  ${CHECK} cloudflared installed successfully."
}

if command -v cloudflared &> /dev/null; then
    cloudflared_bin="cloudflared"
else
    install_cloudflared
fi

# ---- Start tunnel inside tmux session 'tun' ----
echo -e "  ${GLOBE} Starting Cloudflare tunnel in tmux session 'tun'..."
script_dir="$(cd "$(dirname "$0")" && pwd)"
tmux new-session -d -s tun "bash -c 'cd \"$script_dir\" && exec $cloudflared_bin tunnel --url http://localhost:$litellm_docker_port --loglevel $cloudflared_log_level'"

# ---- Extract tunnel URL from logs ----
tunnel_url=""
echo -e "  ${CLOCK} Waiting for tunnel URL..."
for i in $(seq 1 30); do
    # Bail if tmux session died
    if ! tmux has-session -t tun 2>/dev/null; then
        echo -e "\n  ${CROSS} tmux session 'tun' died unexpectedly. Logs:"
        tmux capture-pane -t tun -p -S -
        exit 1
    fi
    tunnel_url=$(tmux capture-pane -t tun -p -J -S - | grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' | head -1)
    if [ -n "$tunnel_url" ]; then
        break
    fi
    sleep 1
done

if [ -z "$tunnel_url" ]; then
    echo -e "\n  ${CROSS} Failed to obtain tunnel URL within 30s. Logs:"
    tmux capture-pane -t tun -p -S -
    exit 1
fi

echo "Tunnel URL: $tunnel_url"
echo

# ---- Wait for tunnel readiness (DNS + HTTP 200) ----
echo -e "  ${CLOCK} Waiting for tunnel to be ready (DNS + HTTP 200)..."
ready=false
for i in $(seq 1 "$max_readiness_retries"); do
    # Check tmux session is alive
    if ! tmux has-session -t tun 2>/dev/null; then
        echo -e "\n  ${CROSS} tmux session 'tun' died during readiness check. Logs:"
        tmux capture-pane -t tun -p -S -
        exit 1
    fi

    # Check HTTP 200 (this implicitly verifies DNS too)
    # (-4 forces IPv4; container has no IPv6 connectivity)
    echo curl -4 -v --max-time 5 "$tunnel_url/"
    curl -4 -v --max-time 5 "$tunnel_url/"
    http_code=$(curl -s -4 -o /dev/null -w "%{http_code}" --max-time 5 "$tunnel_url/" 2>/dev/null)
    if [ "$http_code" = "200" ]; then
        ready=true
        break
    fi
    echo -n "."
    sleep 2
done

echo
if [ "$ready" = true ]; then
    echo -e "  ${CHECK} Tunnel is ready."
    echo -e "  ${INFO} You can access the Litellm UI at: ${BOLD}${tunnel_url}/ui${RESET}"
    echo
    echo -e "  ${INFO} The tunnel is running in tmux session 'tun'."
    echo -e "  ${INFO}   Attach:  ${BOLD}tmux attach -t tun${RESET}"
    echo -e "  ${INFO}   Detach:  ${BOLD}Ctrl+B, D${RESET}"
    echo -e "  ${INFO}   Kill:    ${BOLD}tmux kill-session -t tun${RESET}"
else
    echo -e "\n  ${CROSS} Tunnel never became ready after ${max_readiness_retries} retries."
    echo -e "  ${INFO} Check that litellm is running on port ${litellm_docker_port} and try again."
    tmux kill-session -t tun 2>/dev/null
    exit 1
fi
