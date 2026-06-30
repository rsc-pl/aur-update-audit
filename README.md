# aur-update-audit

`aur-update-audit` creates a read-only audit bundle for pending AUR package updates.

It is meant for users who want to inspect AUR update safety before running their AUR helper, especially after supply-chain or malware incidents.

The generated bundle contains AUR recipe diffs, current and installed-version package trees, `.SRCINFO`, `PKGBUILD`, install hooks, source/checksum summaries, red-flag grep results, local pacman metadata, and a ready-to-use AI review prompt.

## What it does

By default, the script reads pending AUR updates from:

```bash
paru -Qua
```

or, if `paru` is not installed:

```bash
yay -Qua
```

Then it creates a compressed audit archive under your home directory.

You can upload or send this archive to a reviewer, or inspect it manually.

## What it does not do

The script does **not**:

- run `makepkg`
- source `PKGBUILD`
- build packages
- install packages
- run package install hooks
- update your system

It only clones AUR Git repositories and collects text metadata/diffs.

## Requirements

Required:

- Bash
- Git
- pacman
- curl
- tar
- sed
- awk
- grep

For automatic update detection, install one of:

- `paru`
- `yay`

Manual package mode works without `paru`/`yay`.

## Installation

Clone the repository and make the script executable:

```bash
git clone https://github.com/YOUR-USERNAME/aur-update-audit.git
cd aur-update-audit
chmod +x aur-update-audit.sh
```

## Usage

Audit all pending AUR updates:

```bash
./aur-update-audit.sh
```

Force `paru`:

```bash
./aur-update-audit.sh --manager paru
```

Force `yay`:

```bash
./aur-update-audit.sh --manager yay
```

Save the output somewhere else:

```bash
./aur-update-audit.sh --output-dir ~/Desktop
```

Audit selected packages manually:

```bash
./aur-update-audit.sh antigravity hermes-agent-desktop-bin aegisub-git
```

Create a smaller bundle:

```bash
./aur-update-audit.sh --no-bundles --no-upstream-git
```

Show help:

```bash
./aur-update-audit.sh --help
```

## Output

The script creates a folder and a `.tar.gz` archive like:

```text
~/aur-update-audit-20260630-102144/
~/aur-update-audit-20260630-102144.tar.gz
```

The archive contains a `reports/` directory.

Important files include:

- `reports/SUMMARY.tsv`
- `reports/AUR_UPDATES_RAW.txt`
- `reports/AUDIT_PROMPT.md`
- `reports/README.md`
- `reports/<package>/META.txt`
- `reports/<package>/current-files/PKGBUILD`
- `reports/<package>/current-files/.SRCINFO`
- `reports/<package>/AUR_PKGBUILD_SRCINFO_DIFF.patch`
- `reports/<package>/AUR_FULL_DIFF_FROM_INSTALLED.patch`
- `reports/<package>/REDFLAGS_CURRENT_TREE.txt`
- `reports/<package>/REDFLAGS_FULL_DIFF.txt`

## How to review a bundle

Start with:

```text
reports/SUMMARY.tsv
reports/AUR_UPDATES_RAW.txt
```

Then inspect each package directory.

The most important files are usually:

```text
META.txt
AUR_PKGBUILD_SRCINFO_DIFF.patch
AUR_INSTALL_FILES_DIFF.patch
AUR_FULL_DIFF_FROM_INSTALLED.patch
SOURCE_AND_SUMS_CURRENT.txt
SOURCE_AND_SUMS_INSTALLED.txt
REDFLAGS_CURRENT_TREE.txt
REDFLAGS_FULL_DIFF.txt
current-files/PKGBUILD
current-files/.SRCINFO
current-files/*.install
```

For `-git` or VCS packages, also check:

```text
upstream-git/
```

## Red flags worth checking

The script greps for suspicious or sensitive patterns such as:

- `curl`, `wget`, especially when piped to shell
- `eval`
- `base64`
- `systemctl`
- `crontab`
- `post_install`, `post_upgrade`, `pre_install`
- writes to `HOME`
- references to `ssh`, `token`, `wallet`, `keyring`
- `sudo`, `su`, `doas`, `pkexec`
- `setcap`
- services and timers

A grep hit is **not** automatically malicious. It only means the line deserves review.

For example, these are often normal:

- `install -Dm` inside `package()`
- `.desktop` files
- icons
- symlinks
- `chmod 4755 chrome-sandbox` for Chromium-based browsers
- normal CVE/build-fix/security patches

## Security model

This tool reduces risk by collecting update information without executing package build scripts.

However, it cannot prove that a package is safe.

AUR packages are user-submitted build recipes. You should still review:

- changed sources
- changed checksums
- install hooks
- maintainer changes
- new binary download locations
- unpinned `raw.githubusercontent.com` sources
- `sha256sums=('SKIP')` on binary downloads
- unexpected large patches

## AI-assisted review

Every generated bundle contains:

```text
reports/AUDIT_PROMPT.md
```

You can paste that prompt into an AI assistant together with the archive and ask for a practical update-risk assessment.

Suggested message:

```text
Analyze this AUR update audit bundle.
```

The prompt inside the bundle already contains detailed review instructions.

## Limitations

- The script relies on AUR Git history to match the installed version to an old recipe commit. This usually works, but not always.
- VCS packages can be harder to audit because the installed version may contain an upstream commit hash rather than a stable release.
- The script does not verify downloaded source checksums itself; it records the AUR recipe’s declared sources and checksums for review.
- Split packages are resolved through the AUR RPC API. If the RPC query fails, the script falls back to the package name.
- The script does not inspect built artifacts or downloaded source archives.

## Suggested repository structure

```text
aur-update-audit/
├── aur-update-audit.sh
└── README.md
```
