#!/bin/bash

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

litellm_docker_port=4000

echo -e "  ${GLOBE} Starting Cloudflare tunnel..."
tmp_log=$(mktemp)
$cloudflared_bin tunnel --url "http://localhost:$litellm_docker_port" --loglevel "$cloudflared_log_level" >"$tmp_log" 2>&1 &
cloudflared_pid=$!

tunnel_url=""
echo -e "  ${CLOCK} Waiting for tunnel URL..."
for i in $(seq 1 30); do
    tunnel_url=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$tmp_log" | head -1)
    if [ -n "$tunnel_url" ]; then
        break
    fi
    sleep 1
done

echo "Tunnel URL: $tunnel_url"
echo
sleep 1  # Give the tunnel a moment to start

echo -e "  ${CLOCK} Waiting for tunnel to be ready..."
# check until tunnel is ready (does not return 502)
until curl -s -o /dev/null -w "%{http_code}" "$tunnel_url/" | grep -q "200"; do
    echo -n "."
    sleep 2
done
echo

echo
echo -e "  ${CHECK} Tunnel is ready."
echo -e "  ${INFO} You can access the Litellm UI at: ${BOLD}${tunnel_url}/ui${RESET}"
echo
