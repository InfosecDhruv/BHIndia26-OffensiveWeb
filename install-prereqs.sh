#!/usr/bin/env bash
#
# BHIndia26 - student Kali Linux prerequisite installer
#
#
# Does NOT touch Kali's default `java` - installs a standalone JDK 8
# under ~/Tools/jdk8 instead, since ysoserial needs JDK 8 specifically
#
# What this script can't do for you (manual, one-time, inside the app):
#   - Burp Suite itself (assumed already installed on Kali)
#   - Burp BApp Store extensions "IP Rotate" and "Wsdler" - install
#     from Burp's Extender/BApp Store tab, not scriptable from a shell
#
# Usage: chmod +x install-prereqs.sh && ./install-prereqs.sh

set -uo pipefail

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
ok()   { printf '\033[1;32m  ok:\033[0m %s\n' "$1"; }
skip() { printf '\033[1;33m  skip:\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m  FAILED:\033[0m %s\n' "$1"; }

FAILED_STEPS=()
run_step() {
  local desc="$1"; shift
  if "$@"; then
    ok "$desc"
  else
    fail "$desc"
    FAILED_STEPS+=("$desc")
  fi
}

# ---------------------------------------------------------------------------
log "Updating apt package lists"
sudo apt-get update -y || true

# ---------------------------------------------------------------------------
log "Installing apt packages already in Kali's repos"
# git, curl, wget         - recon/scripting basics, used everywhere
# maven                   - builds ysoserial (Sangam ex.15, Web Pentest ex.3)
# jq                      - pretty-prints JSON (StashVault)
# dnsutils                - dig/nslookup (subdomain takeover, DNS exfil)
# netcat-traditional      - reverse shell listener (Web Pentest ex.3)
# python3-pip             - for pip-installed tools below
# golang-go               - builds interactsh-client from source
# sqlmap                  - usually preinstalled on Kali; apt-get is a no-op if so
APT_PACKAGES=(git curl wget maven jq dnsutils netcat-traditional python3-pip golang-go sqlmap)
run_step "apt install: ${APT_PACKAGES[*]}" sudo apt-get install -y "${APT_PACKAGES[@]}"

# ---------------------------------------------------------------------------
log "Installing padding-oracle-attacker (poattack) via pipx"
# Kali's Python is "externally managed" (PEP 668) - pipx is the clean way
# to install a CLI tool without fighting system pip.
if ! command -v pipx >/dev/null 2>&1; then
  run_step "apt install pipx" sudo apt-get install -y pipx
  pipx ensurepath >/dev/null 2>&1 || true
fi
if command -v poattack >/dev/null 2>&1; then
  skip "poattack already installed"
else
  run_step "pipx install padding-oracle-attacker" pipx install padding-oracle-attacker
fi

# ---------------------------------------------------------------------------
log "Installing interactsh-client (OOB callback tool)"
if command -v interactsh-client >/dev/null 2>&1; then
  skip "interactsh-client already installed"
else
  export GOPATH="${GOPATH:-$HOME/go}"
  export PATH="$PATH:$GOPATH/bin"
  if run_step "go install interactsh-client" go install -v github.com/projectdiscovery/interactsh/cmd/interactsh-client@latest; then
    if [ -f "$GOPATH/bin/interactsh-client" ]; then
      run_step "symlink interactsh-client into /usr/local/bin" sudo ln -sf "$GOPATH/bin/interactsh-client" /usr/local/bin/interactsh-client
    fi
  fi
fi

# ---------------------------------------------------------------------------
log "Installing ngrok (reverse-shell tunnel, Web Pentest ex.3)"
if command -v ngrok >/dev/null 2>&1; then
  skip "ngrok already installed"
else
  run_step "add ngrok apt repo + install" bash -c '
    curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
      | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null \
    && echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
      | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null \
    && sudo apt-get update -y \
    && sudo apt-get install -y ngrok
  '
  echo "  (After this, run: ngrok config add-authtoken <your-token>"
  echo "   - needs a free ngrok.com account, one per student or one shared instructor account.)"
fi

# ---------------------------------------------------------------------------
log "Installing LibreOffice (opening DOCX/XLSX/EPUB/ONIX artifacts in the XXE lab)"
if command -v libreoffice >/dev/null 2>&1; then
  skip "libreoffice already installed"
else
  run_step "apt install libreoffice" sudo apt-get install -y libreoffice
fi

# ---------------------------------------------------------------------------
log "Installing AWS CLI v2 (StashVault exercises)"
if command -v aws >/dev/null 2>&1; then
  skip "aws CLI already installed ($(aws --version 2>&1 | head -1))"
else
  run_step "install AWS CLI v2" bash -c '
    cd /tmp \
    && curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip \
    && unzip -q -o awscliv2.zip \
    && sudo ./aws/install \
    && rm -rf awscliv2.zip aws
  '
fi

# ---------------------------------------------------------------------------
log "Installing a standalone JDK 8 for ysoserial (scoped to ~/Tools/jdk8)"
JDK8_DIR="$HOME/Tools/jdk8"
if [ -d "$JDK8_DIR" ] && find "$JDK8_DIR" -maxdepth 1 -iname 'jdk8u*' | grep -q .; then
  skip "JDK 8 already present under $JDK8_DIR"
else
  mkdir -p "$JDK8_DIR"
  ARCH="$(uname -m | sed 's/x86_64/x64/; s/aarch64/aarch64/')"
  run_step "download + extract Adoptium JDK 8 ($ARCH)" bash -c "
    set -e
    cd '$JDK8_DIR'
    URL=\$(curl -s \"https://api.adoptium.net/v3/assets/latest/8/hotspot?architecture=$ARCH&image_type=jdk&os=linux\" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)[0][\"binary\"][\"package\"][\"link\"])')
    curl -sL -o jdk8.tar.gz \"\$URL\"
    tar xzf jdk8.tar.gz
    rm jdk8.tar.gz
  "
fi

JDK8_HOME=$(find "$JDK8_DIR" -maxdepth 1 -iname 'jdk8u*' | head -1)
if [ -n "$JDK8_HOME" ]; then
  # Drop a one-liner helper students can `source` to switch into JDK 8 for
  # the ysoserial build steps, without ever touching the system default java.
  cat > "$HOME/Tools/jdk8/activate.sh" <<EOF
# source this file to use JDK 8 in the current shell for ysoserial:
#   source ~/Tools/jdk8/activate.sh
export JAVA_HOME="$JDK8_HOME"
export PATH="\$JAVA_HOME/bin:\$PATH"
EOF
  ok "JDK 8 ready at $JDK8_HOME - students run: source ~/Tools/jdk8/activate.sh"
else
  fail "could not locate extracted JDK 8 directory under $JDK8_DIR"
  FAILED_STEPS+=("JDK 8 setup")
fi

# ---------------------------------------------------------------------------
log "Sanity-checking everything that should now be on PATH"
for bin in git curl wget mvn jq dig nslookup nc python3 pip3 go sqlmap poattack interactsh-client ngrok aws libreoffice; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin -> $(command -v "$bin")"
  else
    fail "$bin not found on PATH"
    FAILED_STEPS+=("$bin on PATH")
  fi
done

# ---------------------------------------------------------------------------
log "Done."
if [ "${#FAILED_STEPS[@]}" -eq 0 ]; then
  echo "All automated steps succeeded."
else
  echo "The following steps need a manual look:"
  for s in "${FAILED_STEPS[@]}"; do echo "  - $s"; done
fi

cat <<'EOF'

Manual steps NOT covered by this script (do these once, by hand):
  1. Burp Suite - install the "IP Rotate" and "Wsdler" BApps from the
     BApp Store tab inside Burp itself.
  2. IP Rotate (Sarthi HR exercise 6) needs a real AWS access key with
     API Gateway permissions - create one in the AWS IAM console.
  3. StashVault exercises need `aws configure` run with real credentials
     at exercise time (the stolen/presigned creds come from the app itself).
  4. ngrok needs `ngrok config add-authtoken <token>` with a free
     ngrok.com account before it will open tunnels.
  5. GitHub account - needed for Sarthi HR exercise 13 (subdomain takeover).
  6. jwt.io / CyberChef (gchq.github.io/CyberChef) are browser-based,
     nothing to install - just have a browser tab ready.
  7. For any step that needs JDK 8 (ysoserial build/run), run:
       source ~/Tools/jdk8/activate.sh
     first, in that terminal only - it does not change the system default.
EOF
