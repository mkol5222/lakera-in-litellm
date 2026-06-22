#!/bin/bash

# ---- Config ----
litellm_docker_port=4000
max_readiness_retries=30                  # ~60s timeout for readiness check

# ---- Emoji helpers (if not already defined by caller) ----
: "${TOOL:=🔧}"; : "${CROSS:=❌}"; : "${DOWNLOAD:=📥}"
: "${CHECK:=✅}"; : "${GLOBE:=🌍}"; : "${CLOCK:=⏳}"; : "${INFO:=ℹ️}"
: "${BOLD:=}"; : "${RESET:=}"

# ---- Verify we are running inside a GitHub Codespace ----
if [ -z "$CODESPACE_NAME" ]; then
    echo -e "  ${CROSS} This script must run inside a GitHub Codespace."
    echo -e "  ${INFO} CODESPACE_NAME is not set. Aborting."
    exit 1
fi

if [ -z "$GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN" ]; then
    echo -e "  ${CROSS} GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN is not set."
    echo -e "  ${INFO} Are you really inside a Codespace? Aborting."
    exit 1
fi

echo -e "  ${CHECK} Running in Codespace: ${BOLD}${CODESPACE_NAME}${RESET}"

# ---- Verify gh CLI is available ----
if ! command -v gh &> /dev/null; then
    echo -e "  ${CROSS} 'gh' CLI not found. Install it or run inside a Codespace with gh pre-installed."
    exit 1
fi

echo -e "  ${CHECK} gh CLI is available."

# ---- Derive the forwarded URL ----
tunnel_url="https://${CODESPACE_NAME}-${litellm_docker_port}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
echo -e "  ${GLOBE} Codespace port-forward URL: ${BOLD}${tunnel_url}${RESET}"

# ---- Make the port public via gh CLI ----
echo -e "  ${TOOL} Setting port ${litellm_docker_port} visibility to public..."
if gh codespace ports visibility "${litellm_docker_port}:public" -c "${CODESPACE_NAME}" 2>/dev/null; then
    echo -e "  ${CHECK} Port ${litellm_docker_port} is now public."
else
    # gh CLI may require --repo or may already be public — surface the raw output
    echo -e "  ${TOOL} Retrying with verbose output..."
    gh codespace ports visibility "${litellm_docker_port}:public" -c "${CODESPACE_NAME}"
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "  ${CROSS} Failed to set port visibility (exit code $exit_code)."
        echo -e "  ${INFO} You can set it manually: gh codespace ports visibility ${litellm_docker_port}:public -c ${CODESPACE_NAME}"
        exit 1
    fi
fi

# ---- Wait for tunnel readiness (HTTP 200) ----
echo -e "  ${CLOCK} Waiting for tunnel to be ready (HTTP 200 on ${tunnel_url}/)..."
ready=false
for i in $(seq 1 "$max_readiness_retries"); do
    http_code=$(curl -s -4 -o /dev/null -w "%{http_code}" --max-time 5 "${tunnel_url}/" 2>/dev/null)
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
    echo -e "  ${INFO} LiteLLM UI: ${BOLD}${tunnel_url}/ui${RESET}"
    echo
    echo -e "  ${INFO} The port forward stays active as long as this Codespace session is open."
    echo -e "  ${INFO} To list ports:  ${BOLD}gh codespace ports -c ${CODESPACE_NAME}${RESET}"
    echo -e "  ${INFO} To make private again: ${BOLD}gh codespace ports visibility ${litellm_docker_port}:private -c ${CODESPACE_NAME}${RESET}"
else
    echo -e "\n  ${CROSS} Tunnel never became ready after ${max_readiness_retries} retries (~$((max_readiness_retries * 2))s)."
    echo -e "  ${INFO} Check that LiteLLM is running on port ${litellm_docker_port} and try again."
    exit 1
fi
