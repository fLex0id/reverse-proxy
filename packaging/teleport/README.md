# Teleport repository — RPM and APT updates from your GitHub Releases

**Your only recurring task:** publish a GitHub Release named `teleport-vX.Y.Z`
with exactly the server RPM and DEB assets. GitHub Actions automatically builds,
signs and publishes DNF/APT metadata to GitHub Pages. Hosts consume the packages
using their normal `dnf update` and `apt update && apt dist-upgrade`.

This is separate from rp.sh gateway development. No running Teleport or rp.sh
installation is modified by repository publication.

## ONE-TIME INITIALIZATION (publisher)

1. On a trusted Linux workstation, install `gh` (GitHub CLI) and `gpg`, then
   authenticate with `gh auth login` as the repository owner. Do not run the
   following setup as root.

2. Download the setup script from the **review branch** and inspect it:

   ~~~bash
   curl -fsSL https://raw.githubusercontent.com/fLex0id/reverse-proxy/infra/teleport-package-repository/packaging/teleport/setup-publisher.sh -o setup-publisher.sh
   less setup-publisher.sh
   bash setup-publisher.sh
   ~~~

   The script creates a **dedicated password-protected GPG signing key** in
   `~/.gnupg-teleport-repo/`, uploads its protected export and passphrase
   as GitHub Actions secrets, and attempts to enable GitHub Pages with
   **Actions** as its source. If Pages API setup fails, use GitHub UI:
   Settings → Pages → Build and deployment → Source → GitHub Actions.

   **Write down the 40-character GPG fingerprint printed by the script.**
   It is required once on every server. Keep a private offline backup of
   `~/.gnupg-teleport-repo/`. Do not share the private signing key.

3. Review and merge PR #3 into `main`:
   https://github.com/fLex0id/reverse-proxy/pull/3

4. Open GitHub Actions → **Publish approved Teleport package repositories** →
   Run workflow (main). Wait until the workflow and Pages deployment succeed.

5. Verify that these URLs work:
   - https://flex0id.github.io/reverse-proxy/
   - https://flex0id.github.io/reverse-proxy/apt/dists/stable/InRelease
   - https://flex0id.github.io/reverse-proxy/rpm/x86_64/repodata/repomd.xml

Only after successful publication configure Linux servers.

## ONE-TIME INITIALIZATION (each Rocky Linux / Ubuntu host)

Run as root through ordinary SSH, not your only Teleport connection:

~~~bash
curl -4fsSL https://raw.githubusercontent.com/fLex0id/reverse-proxy/main/packaging/teleport/install-repo.sh -o /tmp/install-teleport-repo.sh
TELEPORT_REPO_EXPECTED_FPR='YOUR_OFFLINE_VERIFIED_40_HEX_FINGERPRINT' bash /tmp/install-teleport-repo.sh
~~~

The installer identifies the OS, verifies the trusted signing key and signed
metadata, and creates native repo configuration. It does not restart Teleport.

Rocky Linux:

~~~bash
dnf update
~~~

Ubuntu / Debian:

~~~bash
apt update && apt dist-upgrade
~~~

Keep only this Teleport repository enabled. If additional repositories also
offer the package named `teleport`, disable them or inspect priorities. The
APT installer pins the package name to this GitHub Pages origin.

## EVERY FUTURE TELEPORT RELEASE (your manual task)

1. Obtain the official server packages and independently verify their source.
2. In https://github.com/fLex0id/reverse-proxy/releases create a draft
   release tag `teleport-v18.11.14` (example).
3. Add these exact **server** package filenames:
   - `teleport-18.11.14-1.x86_64.rpm`
   - `teleport_18.11.14_amd64.deb`
4. Click **Publish release**. The workflow detects the highest published
   Teleport version, checks asset SHA256 and package metadata, and updates
   the signed RPM/APT repository. Teleport Connect client packages are ignored.
5. When the workflow is green, ordinary DNF/APT updates offer that version.

If a release was published before both server files were uploaded, rerun the
workflow manually. An unsuccessful job does not deploy a new repository site.

## Important operational constraints

- Keep old GitHub Releases for rollback. Pages only serves the latest approved
  server RPM and DEB (around 458 MB total for 18.11.13).
- Update the Teleport Auth/Proxy cluster **before** SSH agents. A package update
  is not a guarantee that an already running Teleport process restarted: verify
  version and service state through an independent SSH connection.
- Hosts where Teleport is not registered as an RPM/DEB package require a
  one-time safe conversion to package-managed installation.
- RPM repo metadata is GPG-signed (`repo_gpgcheck=1`), but individual RPM
  packages are not re-signed (`gpgcheck=0`); package SHA256 is authenticated
  through signed repository metadata. APT uses GPG-signed InRelease.
- GitHub Release asset digests prove integrity against the uploaded file, not
  independent provenance from Teleport's upstream manufacturer.
- Protect the publisher account, Actions signing secrets and private GPG key.
  Key expiry/rotation requires updating each host's trust configuration.
- GitHub Pages publication and downloads of ~230 MB packages remain subject
  to GitHub service limits and need real-world smoke testing.

Workflow: `.github/workflows/teleport-packages.yml`
Publisher setup: `packaging/teleport/setup-publisher.sh`
Repository builder: `packaging/teleport/build-repo.sh`
Host bootstrap: `packaging/teleport/install-repo.sh`
