#!/usr/bin/env bash

set -eu
set -o pipefail

source "${BASH_SOURCE[0]%/*}/vercomp.sh"

case "$(uname -m)" in
  x86_64)
    arch="x86_64"
    ;;
  arm64)
    arch="aarch64"
    ;;
  aarch64)
    arch="aarch64"
    ;;
  *)
    echo >&2 "unsupported architecture: $(uname -m)"
    exit 1
esac

case "$OSTYPE" in
  darwin*)
    sys="$arch-darwin"
    ;;
  linux*)
    sys="$arch-linux"
    ;;
  *)
    echo >& "unsupported OS type: $OSTYPE"
    exit 1
esac

# Make sure /nix exists and is writeable
if [ -a /nix ]; then
  if ! [ -w /nix ]; then
    echo >&2 "/nix exists but is not writeable, can't set up lix-quick-install-action"
    exit 1
  else
    rm -rf /nix/var/lix-quick-install-action
  fi
elif [[ "$sys" =~ .*-darwin ]]; then
  sudo $SHELL -euo pipefail << EOF
  echo nix >> /etc/synthetic.conf
  echo -e "run\\tprivate/var/run" >> /etc/synthetic.conf
  /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -B &>/dev/null \
    || /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t &>/dev/null \
    || echo "warning: failed to execute apfs.util"
  diskutil apfs addVolume disk1 APFS nix -mountpoint /nix \
    || diskutil apfs addVolume disk3 APFS nix -mountpoint /nix
  mdutil -i off /nix
  chown $USER /nix
EOF
else
  sudo install -d -o "$USER" /nix
  if [[ "$NIX_ON_TMPFS" == "true" || "$NIX_ON_TMPFS" == "True" || "$NIX_ON_TMPFS" == "TRUE" ]]; then
    sudo mount -t tmpfs -o size=90%,mode=0755,gid="$(id -g)",uid="$(id -u)" tmpfs /nix
  fi
fi

# Fetch and unpack nix archive
if [[ "$sys" =~ .*-darwin ]]; then
  # MacOS tar doesn't have the --skip-old-files, so we use gtar
  tar=gtar
else
  tar=tar
fi
rel="$(head -n1 "$RELEASE_FILE")"
# TODO(ttlgcc): Uncomment line below after bootstrapping the repository.
# url="${NIX_ARCHIVES_URL:-https://github.com/fabrictest/lix-quick-install-action/releases/download/$rel}/lix-$NIX_VERSION-$sys.tar.zstd"
url="https://github.com/nixbuild/nix-quick-install-action/releases/download/v29/nix-2.24.9-$sys.tar.zstd"

echo >&2 "Fetching lix archives from $url"
case "$url" in
  file://)
    "$tar" --skip-old-files --strip-components 1 -x -I unzstd -C /nix "${url#file://}"
    ;;
  *)
    curl -sL --retry 3 --retry-connrefused "$url" \
      | "$tar" --skip-old-files --strip-components 1 -x -I unzstd -C /nix
    ;;
esac

# Setup nix.conf
NIX_CONF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"
mkdir -p "$(dirname "$NIX_CONF_FILE")"
touch "$NIX_CONF_FILE"
if [ -n "${NIX_CONF:-}" ]; then
  printenv NIX_CONF > "$NIX_CONF_FILE"
fi

# Setup GitHub access token
if [[ -n "${GITHUB_ACCESS_TOKEN:-}" ]]; then
  echo >>"$NIX_CONF_FILE" \
    "access-tokens = github.com=$GITHUB_ACCESS_TOKEN"
fi

# Setup Flakes
echo >>"$NIX_CONF_FILE" \
  "experimental-features = nix-command flakes"
echo >>"$NIX_CONF_FILE" \
  "accept-flake-config = true"


# Populate the nix db
#
# TODO(ttlgcc): Uncomment line below after bootstrapping the repository.
# nix="$(readlink /nix/var/lix-quick-install-action/nix)"
nix="$(readlink /nix/var/nix-quick-install-action/nix)"
retries=2
while true; do
  "$nix/bin/nix-store" \
    --load-db < /nix/var/nix-quick-install-action/registration && break || true
    # --load-db < /nix/var/lix-quick-install-action/registration && break || true
  ((retries--))
  echo >&2 "Retrying Nix DB registration"
  sleep 2
done


# Install nix in profile
MANPATH= . "$nix/etc/profile.d/nix.sh"
"$nix/bin/nix-env" -i "$nix"

# Certificate bundle is not detected by nix.sh on macOS.
if [ -z "${NIX_SSL_CERT_FILE:-}" -a -e "/etc/ssl/cert.pem" ]; then
  NIX_SSL_CERT_FILE="/etc/ssl/cert.pem"
fi

# Set env
echo "$HOME/.nix-profile/bin" >> $GITHUB_PATH
echo "NIX_PROFILES=/nix/var/nix/profiles/default $HOME/.nix-profile" >> $GITHUB_ENV
echo "NIX_USER_PROFILE_DIR=/nix/var/nix/profiles/per-user/$USER" >> $GITHUB_ENV
echo "NIX_SSL_CERT_FILE=$NIX_SSL_CERT_FILE" >> $GITHUB_ENV
