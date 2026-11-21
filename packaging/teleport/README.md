# Managed Teleport RPM/APT repositories (GitHub Releases → Actions → Pages)

This is independent of the running rp.sh gateway and its Teleport service.
It publishes only the latest published teleport-vMAJOR.MINOR.PATCH **server**
packages: one x86_64 RPM and one amd64 DEB. Teleport Connect is excluded.

## One-time GitHub configuration

1. Merge the reviewed changes into main only when ready.
2. Go to **Settings → Pages → Build and deployment → Source: GitHub Actions**.
3. Create a dedicated GPG signing key on a trusted Linux administrative computer.
   Do NOT reuse your SSH or personal signing key. For example:

   ~~~bash
   export GNUPGHOME="$HOME/.gnupg-teleport-repo"
   mkdir -p "$GNUPGHOME"
   chmod 700 "$GNUPGHOME"
   gpg --quick-generate-key 'fLex0id Teleport Package Repo' ed25519 sign 2y
   gpg --list-secret-keys --fingerprint
   ~~~

   Save the **40-character full fingerprint** independently, and back up this
   signing key privately/offline. Supply a strong passphrase when prompted.

4. After running gh auth login on the same administrative machine, configure
   the two **GitHub Actions repository secrets**. Never commit the private key:

   ~~~bash
   gpg --armor --export-secret-keys > "$HOME/teleport-repo-private.asc"
   chmod 600 "$HOME/teleport-repo-private.asc"
   gh secret set TELEPORT_REPO_GPG_PRIVATE_KEY \
     --repo fLex0id/reverse-proxy < "$HOME/teleport-repo-private.asc"
   read -r -s -p 'Signing passphrase: ' TP_PASSPHRASE; echo
   printf '%s' "$TP_PASSPHRASE" | gh secret set TELEPORT_REPO_GPG_PASSPHRASE \
     --repo fLex0id/reverse-proxy
   unset TP_PASSPHRASE
   ~~~

   Store an encrypted backup of the key **outside GitHub**, and securely remove
   temporary unencrypted exports. Never post the key/passphrase in a chat.

5. From the **Actions** tab run the workflow
   **Publish approved Teleport package repositories** once. It selects the
   highest *published* version with tag teleport-vX.Y.Z. As of 2026-11-21 that
   is teleport-v18.11.13. It verifies GitHub asset SHA256, RPM/DEB package
   names and versions, and signs APT and RPM repository metadata. If anything
   fails, the previous Pages deployment remains untouched.

6. Only after successful Actions deployment, verify these endpoints:

   - https://flex0id.github.io/reverse-proxy/
   - https://flex0id.github.io/reverse-proxy/teleport-repo.asc
   - https://flex0id.github.io/reverse-proxy/signing-fingerprint.txt
   - https://flex0id.github.io/reverse-proxy/apt/dists/stable/InRelease
   - https://flex0id.github.io/reverse-proxy/rpm/x86_64/repodata/repomd.xml

   Verify the fingerprint against your original offline record; do not trust
   the website's fingerprint alone.

## One-time configuration on Rocky Linux or Ubuntu

From an **ordinary SSH session** (not your only Teleport session), retrieve and
inspect packaging/teleport/install-repo.sh from the main branch, then execute
as root with the offline-verified signing fingerprint:

~~~bash
TELEPORT_REPO_EXPECTED_FPR='YOUR_ACTUAL_40_HEX_FINGERPRINT' \
  bash install-repo.sh
~~~

The script first downloads the public key, checks the expected fingerprint, and
verifies the RPM metadata signature or APT InRelease signature. Only then
does it add the repository. It does not install, migrate, or restart Teleport.

For Rocky Linux:

~~~bash
dnf makecache --refresh
dnf update
~~~

For Ubuntu/Debian:

~~~bash
apt update && apt dist-upgrade
~~~

The APT preference file confines the package named teleport to the GitHub Pages
repo. The DNF repo uses priority 1 and includes only teleport; disable any other
Teleport RPM repository explicitly to guarantee single-source policy.

**Upgrade the main Auth/Proxy node before SSH agents.** A package update may
not restart an already-running Teleport service; schedule a controlled restart
and check teleport version, systemctl status teleport and tctl nodes ls.

If Teleport was manually extracted into /usr/local/bin and is not owned by a
package manager, adding this repository alone cannot upgrade it. Migrate that
node to an RPM/DEB installation safely before relying on normal updates.

## Publishing the next version

1. Verify the upstream binary sources yourself.
2. Create a **draft** GitHub Release tagged teleport-vX.Y.Z.
3. Upload the two server artifacts:
   - teleport-X.Y.Z-1.x86_64.rpm
   - teleport_X.Y.Z_amd64.deb
   GUI Teleport Connect artifacts may also be present but are excluded.
4. Only then press **Publish release**. This triggers the GitHub Actions
   workflow automatically. It always selects the numerically latest published
   Teleport release, so an older release event cannot downgrade the channel.
5. Review the Actions result, Pages endpoints and client package-manager output.
   If you published the release before uploading all packages, run the workflow
   manually after the assets are complete.

## Security and operational limits

- APT validates signed InRelease. DNF validates signed repomd.xml and package
  checksums from its signed metadata (repo_gpgcheck=1).
- DNF gpgcheck=0 is deliberate: this workflow does not add individual RPM
  signatures. Signed repository metadata authenticates the RPM hash; if you
  require signature verification *inside* RPM packages, sign RPM payloads and
  enable gpgcheck=1 in a future hardening change.
- GitHub's asset SHA256 confirms that the file matches the uploaded Release
  asset; **it does not independently establish upstream provenance**.
- Protect the GPG signing key and GitHub Actions secrets, and rotate the key
  before expiry. The signing secret must be configured before publishing.
- The 18.11.13 server RPM and DEB total about 458 MB. GitHub Pages has a 1 GiB
  deployment limit; this repository intentionally publishes only one version.
  If Pages delivery becomes unreliable or too costly, move the identical APT/RPM
  repository layout to object storage/CDN.
- Replacing a latest-only site can briefly give 404 to clients using old cached
  metadata; retry the update. No unattended auto-reboots or restarts are set up.
- Build scripts and Pages configuration are isolated from the running rp.sh.
