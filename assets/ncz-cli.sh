#!/bin/bash
# ncx — NCZ 26.5 agent management CLI
AGENTS="zeroclaw openclaw hermes"

agent_token() {
    local name="$1"
    case "$name" in
        zeroclaw)
            sudo grep -E '^(ZEROCLAW_GATEWAY_TOKEN|ZEROCLAW_API_KEY)' /etc/nclawzero/agent-env 2>/dev/null | head -1
            sudo journalctl -u zeroclaw --no-pager 2>/dev/null | grep -oE 'X-Pairing-Code: [0-9]+' | tail -1
            ;;
        openclaw)
            sudo cat /var/lib/nclawzero/openclaw-home/openclaw.json 2>/dev/null \
                | python3 -c "import sys,json; c=json.load(sys.stdin); print('OpenClaw token:', c.get('gateway',{}).get('auth',{}).get('token','(not set)'))"
            ;;
        hermes)
            sudo journalctl -u hermes --no-pager 2>/dev/null | grep -oE '(token|api[_-]key)[^[:space:]]*' | tail -3
            ;;
    esac
}

agent_show() {
    local name="$1"
    case "$name" in
        zeroclaw)
            echo "ZeroClaw"
            echo "  URL:        http://127.0.0.1:42617/"
            echo "  Web UI:     yes (Vite/React; first-time pairing required)"
            echo "  Pairing:    POST /pair with header 'X-Pairing-Code: <code>'"
            echo "  Code:       (printed in journal at startup; rotates on restart)"
            sudo journalctl -u zeroclaw --no-pager 2>/dev/null | grep -A1 -E 'PAIRING|pairing-code' | tail -5
            ;;
        openclaw)
            echo "OpenClaw"
            echo "  URL:        http://127.0.0.1:18789/"
            echo "  Auth mode:  token (Bearer)"
            echo -n "  Token:      "
            sudo cat /var/lib/nclawzero/openclaw-home/openclaw.json 2>/dev/null \
                | python3 -c "import sys,json; print(json.load(sys.stdin).get('gateway',{}).get('auth',{}).get('token','(not set)'))"
            echo "  Web UI:     paste the token at first login"
            echo "  Reset:      sudo openclaw doctor --fix  (regenerates token)"
            ;;
        hermes)
            echo "Hermes"
            echo "  URL:        http://127.0.0.1:8642/  (loopback only — SSH-tunnel to access remotely)"
            echo "  Auth mode:  --insecure (no token; loopback-restricted)"
            echo "  CLI:        hermes (host wrapper) or 'sudo podman exec -it -u hermes hermes /opt/hermes/.venv/bin/hermes'"
            ;;
        *) echo "Unknown agent: $name"; return 1 ;;
    esac
}

case "$1" in
    agent)
        case "$2" in
            list|"")
                echo "NCZ agents:"
                for a in $AGENTS; do
                    state=$(systemctl is-active "$a" 2>/dev/null)
                    case "$state" in
                        active) c="\e[32m●\e[0m" ;;
                        activating) c="\e[33m◐\e[0m" ;;
                        *) c="\e[31m○\e[0m" ;;
                    esac
                    printf "  %b %-12s  %s\n" "$c" "$a" "$state"
                done ;;
            status) systemctl status "$3" --no-pager ;;
            start|stop|restart|enable|disable) sudo systemctl "$2" "$3" ;;
            logs)   sudo journalctl -u "$3" -f ;;
            web)
                echo "Agent web dashboards:"
                echo "  zeroclaw:  http://127.0.0.1:42617/"
                echo "  openclaw:  http://127.0.0.1:18789/   (token: run 'ncx agent token openclaw')"
                echo "  hermes:    http://127.0.0.1:8642/    (loopback only)"
                echo "  Cockpit:   https://127.0.0.1:9090/" ;;
            shell)  sudo podman exec -it "$3" /bin/bash 2>/dev/null || sudo podman exec -it "$3" /bin/sh ;;
            token)  agent_token "$3" ;;
            show)   agent_show "$3" ;;
            *) echo "Try: ncx agent {list|status|start|stop|restart|logs|enable|disable|web|shell|token|show}"; exit 1 ;;
        esac ;;
    version|"--version"|"-V")
        echo "NCZ 26.5 \"Reinhardt\""
        [ -f /etc/lsb-release ] && grep DISTRIB_DESCRIPTION /etc/lsb-release | cut -d= -f2- | tr -d '"' ;;
    ""|help|--help|-h)
        cat <<USAGE
ncx — NCZ 26.5 agent CLI
  ncx agent list                show all agents + status
  ncx agent status <name>       detailed status
  ncx agent start|stop|restart <name>
  ncx agent logs <name>         follow journal
  ncx agent enable|disable <name>
  ncx agent web                 list dashboard URLs (with token hints)
  ncx agent shell <name>        shell into the container
  ncx agent token <name>        print the auth token (openclaw + hermes)
  ncx agent show <name>         full info: URL, token, instructions
  ncx version                   NCX version + build info
Available agents: zeroclaw, openclaw, hermes
USAGE
        ;;
    *) echo "Unknown command: $1"; exit 1 ;;
esac
