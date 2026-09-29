#!/bin/bash
# argonas-ssh.sh -- source me. Sets GIT_SSH_COMMAND (and SSHPASS) for git over
# ssh to ARGONAS without any secret in the repo.
#
# Password auth is used only when a mode-0600 env file defining ARGONAS_PASS
# exists (default ~/.config/ncz/argonas.env, override NCZ_ARGONAS_ENV). The
# password is passed through the SSHPASS environment variable (sshpass -e),
# never on a command line. Otherwise plain key/agent auth is used.
#
# Usage: . build/lib/argonas-ssh.sh; ncz_argonas_git_ssh [extra ssh options]
ncz_argonas_git_ssh() {
    local envf="${NCZ_ARGONAS_ENV:-$HOME/.config/ncz/argonas.env}" mode extra="$*"
    if [ -f "$envf" ]; then
        mode="$(stat -c %a "$envf" 2>/dev/null || stat -f %Lp "$envf" 2>/dev/null)"
        if [ "$mode" = 600 ]; then
            # shellcheck disable=SC1090
            SSHPASS="$(. "$envf" >/dev/null 2>&1; printf '%s' "${ARGONAS_PASS:-}")"
            if [ -n "$SSHPASS" ]; then
                export SSHPASS
                export GIT_SSH_COMMAND="sshpass -e ssh -o PubkeyAuthentication=no -o StrictHostKeyChecking=no $extra"
                return 0
            fi
        else
            echo "[argonas-ssh] $envf must be mode 0600 (is $mode); ignoring it" >&2
        fi
    fi
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no $extra"
}
