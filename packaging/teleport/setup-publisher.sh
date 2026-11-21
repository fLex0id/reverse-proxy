#!/usr/bin/env bash
# One-time publisher initialization on YOUR trusted Linux workstation.
# Requires: gh CLI authenticated as repository admin, gpg. Never run as root.
set -Eeuo pipefail
umask 077
[[ $(id -u) -ne 0 ]] || { echo 'Run as your normal GitHub user, not root' >&2; exit 1; }
for cmd in gh gpg awk; do command -v "$cmd" >/dev/null || { echo "Missing program: $cmd" >&2; exit 1; }; done
gh auth status >/dev/null
repo='fLex0id/reverse-proxy'
gh api "repos/$repo" --jq '.full_name' >/dev/null

export GNUPGHOME="$HOME/.gnupg-teleport-repo"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
mapfile -t keys < <(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10}')
if (( ${#keys[@]} == 0 )); then
    echo 'Creating a dedicated signing key for YOUR Teleport package repository.'
    read -r -s -p 'Create a private signing-key passphrase: ' pass; echo
    [[ ${#pass} -ge 12 ]] || { echo 'Use at least a 12-character passphrase' >&2; exit 1; }
    read -r -s -p 'Repeat passphrase: ' confirm; echo
    [[ "$pass" == "$confirm" ]] || { echo 'Passphrases differ' >&2; exit 1; }
    unset confirm
    gpg --batch --pinentry-mode loopback --passphrase-fd 3 \
      --quick-generate-key 'fLex0id Teleport Repository' ed25519 sign 2y 3<<< "$pass"
    mapfile -t keys < <(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10}')
else
    read -r -s -p 'Existing repository key passphrase: ' pass; echo
fi
[[ ${#keys[@]} -eq 1 ]] || { echo 'Expected exactly one signing key in the dedicated GNUPGHOME' >&2; exit 1; }
fingerprint="${keys[0]}"
[[ "$fingerprint" =~ ^[A-F0-9]{40}$ ]] || { echo 'Unexpected fingerprint format' >&2; exit 1; }

printf 'Uploading encrypted-key export to GitHub Actions secret ...\n'
gpg --batch --pinentry-mode loopback --passphrase-fd 3 \
  --armor --export-secret-keys "$fingerprint" 3<<< "$pass" |
  gh secret set TELEPORT_REPO_GPG_PRIVATE_KEY --repo "$repo"
printf '%s' "$pass" | gh secret set TELEPORT_REPO_GPG_PASSPHRASE --repo "$repo"
unset pass

key_file="$HOME/teleport-repo-public.asc"
gpg --armor --export "$fingerprint" > "$key_file"
chmod 644 "$key_file"
printf '\nRepository GPG fingerprint (keep this value for clients):\n%s\n' "$fingerprint"
printf 'Public key: %s\n' "$key_file"
echo 'Back up ~/.gnupg-teleport-repo offline. Never upload this private-key directory to GitHub.'

echo 'Attempting to enable GitHub Pages (GitHub Actions source)...'
if gh api "repos/$repo/pages" >/dev/null 2>&1; then
    if gh api -X PUT "repos/$repo/pages" -f build_type=workflow >/dev/null 2>&1; then
        echo 'GitHub Pages set to Actions source.'
    else
        echo 'Review Settings -> Pages -> Build and deployment -> Source: GitHub Actions'
    fi
elif gh api -X POST "repos/$repo/pages" -f build_type=workflow >/dev/null 2>&1; then
    echo 'GitHub Pages enabled with Actions source.'
else
    echo 'Manual step: Settings -> Pages -> Build and deployment -> Source: GitHub Actions'
fi
echo 'Publisher initialized. Merge the reviewed PR, then run workflow: Publish approved Teleport package repositories.'
