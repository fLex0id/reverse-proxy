#!/usr/bin/env bash
# Produce signed RPM and APT repositories from the newest approved Teleport Release.
# Runs only in trusted GitHub Actions on the repository's default branch.
set -Eeuo pipefail
umask 077

: "${GITHUB_REPOSITORY:?missing GitHub repository}"
: "${GH_TOKEN:?missing read-only GitHub token}"
: "${TELEPORT_REPO_GPG_PRIVATE_KEY:?set the repository Actions secret}"
: "${TELEPORT_REPO_GPG_PASSPHRASE:?set the repository Actions secret}"

out="${1:?usage: build-repo.sh OUTPUT_DIR}"
case "$out" in /*) ;; *) echo 'Output directory must be absolute' >&2; exit 1;; esac
work="$(mktemp -d)"
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT
mkdir -p "$work/downloads" "$out"
export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"
printf '%s\n' "$TELEPORT_REPO_GPG_PRIVATE_KEY" | gpg --batch --quiet --import
printf '%s' "$TELEPORT_REPO_GPG_PASSPHRASE" > "$work/signing.pass"
chmod 600 "$work/signing.pass"

mapfile -t fingerprints < <(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10}')
if (( ${#fingerprints[@]} != 1 )); then
  echo 'Expected exactly one GPG private signing key' >&2
  exit 1
fi
fingerprint="${fingerprints[0]}"

echo 'Discovering the highest published teleport-vX.Y.Z release ...'
gh api --paginate --slurp "repos/${GITHUB_REPOSITORY}/releases?per_page=100" > "$work/releases.json"
python3 - "$work/releases.json" "$work/release.env" "$work/sha256.txt" <<'PY'
import json, re, sys
from pathlib import Path

raw = json.loads(Path(sys.argv[1]).read_text())
releases = [r for batch in raw for r in (batch if isinstance(batch, list) else [batch])]
valid = []
for r in releases:
    tag = r.get('tag_name', '')
    m = re.fullmatch(r'teleport-v(\d+)\.(\d+)\.(\d+)', tag)
    if m and not r.get('draft') and not r.get('prerelease') and r.get('published_at'):
        valid.append((tuple(map(int, m.groups())), r))
if not valid:
    sys.exit('No published Teleport release found')
_, r = max(valid, key=lambda item: item[0])
tag = r['tag_name']
version = tag.removeprefix('teleport-v')
expected = [f'teleport-{version}-1.x86_64.rpm', f'teleport_{version}_amd64.deb']
by_name = {}
for a in r['assets']:
    by_name.setdefault(a['name'], []).append(a)
lines = []
for filename in expected:
    hits = by_name.get(filename, [])
    if len(hits) != 1:
        sys.exit(f'Expected exactly one asset: {filename}')
    asset = hits[0]
    digest = asset.get('digest') or ''
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest) or asset.get('state') != 'uploaded' or asset.get('size', 0) < 1024:
        sys.exit(f'Invalid digest / upload state for {filename}')
    lines.append(f"{digest.split(':', 1)[1]}  {filename}")
Path(sys.argv[2]).write_text(f'{tag}\n{version}\n{expected[0]}\n{expected[1]}\n')
Path(sys.argv[3]).write_text('\n'.join(lines) + '\n')
print(f'Selected published release: {tag}')
PY
mapfile -t release_info < "$work/release.env"
tag="${release_info[0]}"
version="${release_info[1]}"
rpm_name="${release_info[2]}"
deb_name="${release_info[3]}"

# Re-runs and older release events cannot silently downgrade the repository:
# always select the highest published teleport-vX.Y.Z tag.
gh release download "$tag" --repo "$GITHUB_REPOSITORY" \
    --pattern "$rpm_name" --pattern "$deb_name" --dir "$work/downloads"
(cd "$work/downloads" && sha256sum --check "$work/sha256.txt")

rpm_file="$work/downloads/$rpm_name"
deb_file="$work/downloads/$deb_name"
[[ "$(rpm -qp --qf '%{NAME}' "$rpm_file")" == teleport ]]
[[ "$(rpm -qp --qf '%{VERSION}' "$rpm_file")" == "$version" ]]
[[ "$(rpm -qp --qf '%{ARCH}' "$rpm_file")" == x86_64 ]]
[[ "$(dpkg-deb -f "$deb_file" Package)" == teleport ]]
[[ "$(dpkg-deb -f "$deb_file" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$deb_file" Architecture)" == amd64 ]]

rpm_dir="$out/rpm/x86_64"
apt_dir="$out/apt"
mkdir -p "$rpm_dir" "$apt_dir/pool/main" "$apt_dir/dists/stable/main/binary-amd64"
cp -- "$rpm_file" "$rpm_dir/"
cp -- "$deb_file" "$apt_dir/pool/main/"
chmod 644 "$rpm_dir/$rpm_name" "$apt_dir/pool/main/$deb_name"

createrepo_c --quiet "$rpm_dir"
(
    cd "$apt_dir"
    dpkg-scanpackages --arch amd64 pool/main /dev/null > dists/stable/main/binary-amd64/Packages
    gzip -9 -c dists/stable/main/binary-amd64/Packages > dists/stable/main/binary-amd64/Packages.gz
    apt-ftparchive \
        -o 'APT::FTPArchive::Release::Origin=fLex0id' \
        -o 'APT::FTPArchive::Release::Label=Teleport Managed Packages' \
        -o 'APT::FTPArchive::Release::Suite=stable' \
        -o 'APT::FTPArchive::Release::Codename=stable' \
        -o 'APT::FTPArchive::Release::Architectures=amd64' \
        -o 'APT::FTPArchive::Release::Components=main' \
        release dists/stable > dists/stable/Release
)

sign() {
    gpg --batch --yes --pinentry-mode loopback --passphrase-file "$work/signing.pass" \
        --local-user "$fingerprint" "$@"
}
sign --armor --detach-sign \
    --output "$rpm_dir/repodata/repomd.xml.asc" "$rpm_dir/repodata/repomd.xml"
sign --clearsign \
    --output "$apt_dir/dists/stable/InRelease" "$apt_dir/dists/stable/Release"
sign --armor --detach-sign \
    --output "$apt_dir/dists/stable/Release.gpg" "$apt_dir/dists/stable/Release"
gpg --armor --export "$fingerprint" > "$out/teleport-repo.asc"
printf '%s\n' "$fingerprint" > "$out/signing-fingerprint.txt"
printf '%s\n' "$tag" > "$out/current-release.txt"
touch "$out/.nojekyll"
cat > "$out/index.html" <<HTML
<!doctype html><html lang="en"><meta charset="utf-8"><title>Teleport packages</title>
<h1>fLex0id Teleport package repository</h1>
<p>Currently published release: <strong>${tag}</strong></p>
<p>Only the Teleport server package is indexed (no Teleport Connect).</p>
<p>Signed metadata: <a href="apt/dists/stable/InRelease">APT InRelease</a>,
<a href="rpm/x86_64/repodata/repomd.xml">RPM repomd.xml</a>.</p>
<p><a href="teleport-repo.asc">Public signing key</a> and
<a href="signing-fingerprint.txt">its fingerprint</a>.</p></html>
HTML

# Keep only the latest packages to remain below the 1 GiB Pages deployment limit.
bytes="$(du -sb "$out" | awk '{print $1}')"
(( bytes < 850 * 1024 * 1024 )) || { echo "Refusing oversized Pages site: $bytes bytes" >&2; exit 1; }
gpg --batch --verify "$rpm_dir/repodata/repomd.xml.asc" "$rpm_dir/repodata/repomd.xml"
gpg --batch --verify "$apt_dir/dists/stable/Release.gpg" "$apt_dir/dists/stable/Release"
gpg --batch --verify "$apt_dir/dists/stable/InRelease"
echo "Signed Teleport repository for $tag; public key $fingerprint; site bytes=$bytes"
