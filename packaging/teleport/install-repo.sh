#!/usr/bin/env bash
# One-time configuration for apt/dnf to consume the signed GitHub Pages Teleport repo.
# Requires a fingerprint recorded independently of the remote repository.
set -Eeuo pipefail
umask 077

[[ "$(id -u)" -eq 0 ]] || { echo 'Run this as root' >&2; exit 1; }
base='https://flex0id.github.io/reverse-proxy'
expected="${TELEPORT_REPO_EXPECTED_FPR:-}"
expected="${expected^^}"
[[ "$expected" =~ ^[A-F0-9]{40}$ ]] || {
    echo 'Set TELEPORT_REPO_EXPECTED_FPR to the independently verified 40-character GPG fingerprint' >&2
    exit 1
}
command -v curl >/dev/null
command -v gpg >/dev/null
command -v awk >/dev/null
arch="$(uname -m)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
curl -4fsSL --retry 3 --connect-timeout 10 --max-time 60 \
    "$base/teleport-repo.asc" -o "$tmp/key.asc"
actual="$(gpg --batch --show-keys --with-colons "$tmp/key.asc" 2>/dev/null | awk -F: '$1=="fpr"{print toupper($10); exit}')"
[[ "$actual" == "$expected" ]] || { echo "Refusing signing-key mismatch: got $actual" >&2; exit 1; }

if command -v dnf >/dev/null && [[ -f /etc/redhat-release ]]; then
    [[ "$arch" == x86_64 ]] || { echo "Unsupported RPM architecture: $arch" >&2; exit 1; }
    curl -4fsSL --retry 3 "$base/rpm/x86_64/repodata/repomd.xml" -o "$tmp/repomd.xml"
    curl -4fsSL --retry 3 "$base/rpm/x86_64/repodata/repomd.xml.asc" -o "$tmp/repomd.xml.asc"
    gpg --no-default-keyring --keyring "$tmp/check.gpg" --import "$tmp/key.asc" >/dev/null 2>&1
    gpg --no-default-keyring --keyring "$tmp/check.gpg" --verify "$tmp/repomd.xml.asc" "$tmp/repomd.xml"
    install -D -m 0644 "$tmp/key.asc" /etc/pki/rpm-gpg/RPM-GPG-KEY-flex0id-teleport.asc
    cat > /etc/yum.repos.d/flex0id-teleport.repo <<'REPO'
[flex0id-teleport]
name=fLex0id approved Teleport packages
baseurl=https://flex0id.github.io/reverse-proxy/rpm/x86_64/
enabled=1
priority=1
includepkgs=teleport
repo_gpgcheck=1
# The signed repomd.xml authenticates the checksum of the selected RPM.
# RPM payload signatures are not yet issued by this repository.
gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-flex0id-teleport.asc
skip_if_unavailable=0
metadata_expire=1h
REPO
    chmod 644 /etc/yum.repos.d/flex0id-teleport.repo
    echo 'DNF repository installed. Verification:'
    dnf makecache --refresh --disablerepo='*' --enablerepo='flex0id-teleport'
    dnf repoquery --disablerepo='*' --enablerepo='flex0id-teleport' --available teleport || true
elif command -v apt-get >/dev/null && [[ -f /etc/debian_version ]]; then
    [[ "$arch" == x86_64 ]] || { echo "Unsupported APT architecture: $arch" >&2; exit 1; }
    curl -4fsSL --retry 3 "$base/apt/dists/stable/InRelease" -o "$tmp/InRelease"
    gpg --no-default-keyring --keyring "$tmp/check.gpg" --import "$tmp/key.asc" >/dev/null 2>&1
    gpg --no-default-keyring --keyring "$tmp/check.gpg" --verify "$tmp/InRelease"
    install -D -m 0644 "$tmp/key.asc" /etc/apt/keyrings/flex0id-teleport.asc
    cat > /etc/apt/sources.list.d/flex0id-teleport.list <<'REPO'
deb [arch=amd64 signed-by=/etc/apt/keyrings/flex0id-teleport.asc] https://flex0id.github.io/reverse-proxy/apt stable main
REPO
    cat > /etc/apt/preferences.d/flex0id-teleport <<'PIN'
Package: teleport
Pin: origin "flex0id.github.io"
Pin-Priority: 700

Package: teleport
Pin: version *
Pin-Priority: -1
PIN
    chmod 644 /etc/apt/sources.list.d/flex0id-teleport.list /etc/apt/preferences.d/flex0id-teleport

    # APT pinning only chooses package *versions*, not which source serves
    # an identical version. Disable the official vendor's Teleport repository
    # if present, preserving a backup of every changed sources file.
    # Do not alter unrelated repositories or mixed-URI deb822 stanzas.
    command -v python3 >/dev/null || {
        echo 'python3 is required to disable competing Teleport APT sources safely' >&2
        exit 1
    }
    python3 - <<'PY'
from pathlib import Path
import re
import shutil

root = Path("/etc/apt")
paths = [root / "sources.list", *sorted((root / "sources.list.d").glob("*.list")),
         *sorted((root / "sources.list.d").glob("*.sources"))]
host = "apt.releases.teleport.dev"
edits = []

for path in paths:
    if not path.is_file() or path.name == "flex0id-teleport.list":
        continue
    original = path.read_text(encoding="utf-8")
    if host not in original:
        continue
    if path.suffix == ".sources":
        # Deb822: disable only the Teleport-specific stanza.
        sections = re.split(r"(\n[ \t]*\n)", original)
        for i in range(0, len(sections), 2):
            stanza = sections[i]
            uris = re.findall(r"(?mi)^URIs:[ \t]*([^\n]+)", stanza)
            if not any(host in uri for uri in uris):
                continue
            urls = re.findall(r"https?://[^\s]+", " ".join(uris))
            if not urls or any(host not in url for url in urls):
                raise SystemExit(f"Refusing to disable mixed-URI APT stanza in {path}")
            if re.search(r"(?mi)^Enabled:[ \t]*no[ \t]*$", stanza):
                continue
            if re.search(r"(?mi)^Enabled:[ \t]*", stanza):
                stanza = re.sub(r"(?mi)^Enabled:[ \t]*[^\n]*", "Enabled: no",
                                stanza, count=1)
            else:
                stanza = stanza.rstrip("\n") + "\nEnabled: no\n"
            sections[i] = stanza
        updated = "".join(sections)
    else:
        # Traditional *.list and /etc/apt/sources.list: comment only vendor
        # lines; preserve all unrelated entries within the same file.
        lines = []
        for line in original.splitlines(keepends=True):
            if (host in line and
                    re.match(r"^[ \t]*deb(?:-src)?[ \t]+", line)):
                lines.append("# Disabled by flex0id-teleport: " + line)
            else:
                lines.append(line)
        updated = "".join(lines)

    if updated != original:
        edits.append((path, updated))

for path, updated in edits:
    backup = path.with_name(path.name + ".before-flex0id-teleport.bak")
    if not backup.exists():
        shutil.copy2(path, backup)
    path.write_text(updated, encoding="utf-8")
    print(f"Disabled competing official Teleport APT source: {path}")
PY
    echo 'APT repository installed. Verification:'
    apt-get update
    apt-cache policy teleport
else
    echo 'Unsupported Linux distribution or package manager' >&2
    exit 1
fi

echo 'Existing Teleport services and configurations are untouched; package updates use normal dnf/apt commands.'
