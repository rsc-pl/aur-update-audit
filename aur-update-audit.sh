#!/usr/bin/env bash
# aur-update-audit.sh
#
# Generate a safe, read-only audit bundle for pending AUR package updates.
#
# The script:
#   - reads pending AUR updates from paru/yay, or audits manually provided packages
#   - clones the relevant AUR Git repositories
#   - captures PKGBUILD/.SRCINFO/*.install files
#   - compares the currently installed AUR recipe with the latest AUR recipe
#   - collects metadata, source/checksum summaries, commit logs, and red-flag grep hits
#   - optionally captures VCS upstream logs for git-based packages
#   - writes an AI-review prompt into the output bundle
#
# The script does NOT:
#   - run makepkg
#   - source PKGBUILD
#   - build packages
#   - install packages
#   - execute package install hooks

set -uo pipefail
shopt -s nullglob dotglob

SCRIPT_NAME="$(basename "$0")"
AUR_RPC_URL="https://aur.archlinux.org/rpc/v5/info"
AUR_GIT_BASE="https://aur.archlinux.org"

UPDATE_MANAGER="auto"
OUTPUT_PARENT="$HOME"
INCLUDE_BUNDLES=1
INCLUDE_UPSTREAM_GIT=1
MANUAL_PACKAGES=()

usage() {
  cat <<'EOF'
Usage:
  aur-update-audit.sh [options] [package ...]

Default behavior:
  Without package arguments, the script reads pending AUR updates from paru -Qua
  or yay -Qua and audits those packages.

Manual package mode:
  If package names are provided, the script audits those packages instead of
  reading the update list from an AUR helper.

Options:
  -m, --manager auto|paru|yay
      Select the AUR helper used to read updates. Default: auto.

  -o, --output-dir DIR
      Parent directory where the audit folder and .tar.gz archive will be saved.
      Default: $HOME.

  --no-bundles
      Do not include AUR_REPO_FULL_HISTORY.bundle files.
      This makes the output smaller.

  --no-upstream-git
      Do not clone upstream git repositories referenced by git+https sources.
      This makes the output faster and smaller.

  -h, --help
      Show this help.

Examples:
  ./aur-update-audit.sh
  ./aur-update-audit.sh --manager paru
  ./aur-update-audit.sh --output-dir ~/Desktop
  ./aur-update-audit.sh antigravity hermes-agent-desktop-bin aegisub-git
  ./aur-update-audit.sh --no-bundles --no-upstream-git
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARNING: $*" >&2
}

info() {
  echo "$*"
}

need_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--manager)
        [[ $# -ge 2 ]] || die "$1 requires an argument"
        UPDATE_MANAGER="$2"
        shift 2
        ;;
      -o|--output-dir)
        [[ $# -ge 2 ]] || die "$1 requires an argument"
        OUTPUT_PARENT="$2"
        shift 2
        ;;
      --no-bundles)
        INCLUDE_BUNDLES=0
        shift
        ;;
      --no-upstream-git)
        INCLUDE_UPSTREAM_GIT=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          MANUAL_PACKAGES+=("$1")
          shift
        done
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        MANUAL_PACKAGES+=("$1")
        shift
        ;;
    esac
  done

  case "$UPDATE_MANAGER" in
    auto|paru|yay) ;;
    *) die "--manager must be one of: auto, paru, yay" ;;
  esac
}

select_update_manager() {
  if [[ "$UPDATE_MANAGER" == "auto" ]]; then
    if command -v paru >/dev/null 2>&1; then
      UPDATE_MANAGER="paru"
    elif command -v yay >/dev/null 2>&1; then
      UPDATE_MANAGER="yay"
    else
      die "no AUR helper found. Install paru/yay or pass package names manually."
    fi
  fi

  command -v "$UPDATE_MANAGER" >/dev/null 2>&1 || die "selected AUR helper not found: $UPDATE_MANAGER"
}

split_arch_version() {
  local fullver="$1"
  local noepoch pkgver pkgrel

  # Strip epoch: 1:2.3.4-1 -> 2.3.4-1
  noepoch="$(printf '%s\n' "$fullver" | sed -E 's/^[0-9]+://')"

  # Arch pkgver normally cannot contain "-", so the last "-" separates pkgrel.
  pkgver="$(printf '%s\n' "$noepoch" | sed -E 's/-[^-]+$//')"
  pkgrel="$(printf '%s\n' "$noepoch" | sed -E 's/^.*-//')"

  printf '%s\n' "$pkgver"
  printf '%s\n' "$pkgrel"
}

safe_filename() {
  printf '%s\n' "$1" | sed -E 's/[^A-Za-z0-9._-]+/_/g'
}

normalize_git_url() {
  local raw="$1"
  raw="${raw#*git+}"
  raw="${raw%%#*}"
  printf '%s\n' "$raw"
}

extract_possible_hashes() {
  printf '%s\n' "$1" | grep -Eo '[0-9a-f]{7,40}' || true
}

resolve_pkgbase() {
  local pkg="$1"
  local out_json="$2"
  local pkgbase=""

  curl -fsSL --get --data-urlencode "arg[]=$pkg" "$AUR_RPC_URL" > "$out_json" 2>/dev/null || true

  if [[ -s "$out_json" ]]; then
    pkgbase="$(grep -o '"PackageBase":"[^"]*"' "$out_json" | head -n1 | sed -E 's/^"PackageBase":"([^"]*)"/\1/')"
  fi

  if [[ -n "$pkgbase" ]]; then
    printf '%s\n' "$pkgbase"
  else
    printf '%s\n' "$pkg"
  fi
}

find_matching_aur_commit() {
  local repo="$1"
  local pkgver="$2"
  local pkgrel="$3"
  local commit srcinfo pkgbuild

  while read -r commit; do
    srcinfo="$(git -C "$repo" show "$commit:.SRCINFO" 2>/dev/null || true)"

    if [[ -n "$srcinfo" ]]; then
      if grep -Fq "pkgver = $pkgver" <<< "$srcinfo" && grep -Fq "pkgrel = $pkgrel" <<< "$srcinfo"; then
        printf '%s\n' "$commit"
        return 0
      fi
    fi

    pkgbuild="$(git -C "$repo" show "$commit:PKGBUILD" 2>/dev/null || true)"

    if [[ -n "$pkgbuild" ]]; then
      if grep -Eq "^[[:space:]]*pkgver=['\"]?${pkgver//./\\.}['\"]?[[:space:]]*$" <<< "$pkgbuild" \
        && grep -Eq "^[[:space:]]*pkgrel=['\"]?${pkgrel//./\\.}['\"]?[[:space:]]*$" <<< "$pkgbuild"; then
        printf '%s\n' "$commit"
        return 0
      fi
    fi
  done < <(git -C "$repo" rev-list HEAD)

  return 1
}

copy_tree_without_git() {
  local src="$1"
  local dst="$2"

  mkdir -p "$dst"
  tar --exclude='.git' -C "$src" -cf - . | tar -C "$dst" -xf -
}

archive_tree_from_commit() {
  local repo="$1"
  local commit="$2"
  local dst="$3"

  mkdir -p "$dst"
  git -C "$repo" archive "$commit" | tar -C "$dst" -xf -
}

redflag_scan() {
  local src="$1"
  local out="$2"

  grep -RInE \
    --exclude-dir=.git \
    --exclude='*.patch' \
    --exclude='*.log' \
    'curl|wget|npx|npm|node|bun|deno|python -c|python3 -c|perl -e|ruby -e|base64|eval|chmod|chown|setcap|systemctl|crontab|/tmp|/etc|HOME|ssh|token|keyring|wallet|\.service|post_install|pre_install|post_upgrade|install -Dm|install -m|sudo|su |doas|pkexec' \
    "$src" \
    > "$out" 2>/dev/null || true
}

source_and_sums_extract() {
  local src="$1"
  local out="$2"

  grep -RInE \
    --exclude-dir=.git \
    '^[[:space:]]*(pkgbase|pkgname|pkgver|pkgrel|epoch|source|sha256sums|sha512sums|b2sums|validpgpkeys|prepare|build|check|package|post_install|post_upgrade|pre_install)' \
    "$src" \
    > "$out" 2>/dev/null || true
}

write_ai_prompt() {
  local out="$1"

  cat > "$out" <<'EOF'
Analyze the attached AUR update audit bundle generated by aur-update-audit.sh.

Context:
- These are packages with available AUR updates according to paru -Qua / yay -Qua, or manually selected AUR packages.
- The goal is to judge whether the updates look safe after recent AUR malware/supply-chain incidents.
- Do not claim 100% safety. Give a practical risk assessment based on PKGBUILD, .SRCINFO, *.install files, diffs, sources, checksums, metadata, and red-flag grep results.
- Focus mainly on AUR/supply-chain/malware risk, but also mention stability risk when an update is beta/nightly/VCS.
- For hermes-agent-desktop-bin: do not treat the mere fact that the application can install or update a local agent on first run as an automatic red flag. That is normal for this application. Judge whether the PKGBUILD, diffs, or install scripts do anything unusual or suspicious.

How to analyze:
1. Start with SUMMARY.tsv and AUR_UPDATES_RAW.txt.
2. For each package, check:
   - META.txt
   - AUR_PKGBUILD_SRCINFO_DIFF.patch
   - AUR_INSTALL_FILES_DIFF.patch
   - AUR_FULL_DIFF_FROM_INSTALLED.patch or AUR_LAST_20_COMMITS.patch
   - SOURCE_AND_SUMS_CURRENT.txt
   - SOURCE_AND_SUMS_INSTALLED.txt, if present
   - REDFLAGS_CURRENT_TREE.txt
   - REDFLAGS_FULL_DIFF.txt or REDFLAGS_LAST_20_COMMITS.txt
   - current-files/PKGBUILD
   - current-files/.SRCINFO
   - current-files/*.install, if present
3. For -git/VCS packages, also check upstream-git/.
4. Pay special attention to:
   - curl|sh, wget|sh, eval, base64, obfuscated shell
   - new post_install / post_upgrade / pre_install hooks
   - systemctl enable/start, crontab, timers, services
   - writes to HOME, ~/.ssh, keyrings, wallets, tokens
   - sudo/su/doas/pkexec
   - binary downloads from strange domains
   - sha256sums=('SKIP') for binary archives or tarballs
   - maintainer changes or unusual large local patches in AUR
   - raw.githubusercontent.com sources without pinning
   - mismatches between versions, URLs, and checksums
5. Do not panic about normal packaging patterns:
   - install -Dm / install -m inside package()
   - chmod 4755 chrome-sandbox for Chromium/Brave
   - standard .desktop files, icons, symlinks
   - normal build-fix/CVE/security patches
   - pkgver() in VCS packages when it does not do anything suspicious
6. Provide a final table with one verdict per package:
   - update OK
   - update OK, but beta/nightly/VCS/stability caution
   - update only if needed
   - hold
   - remove/replace
7. After the table, add short reasoning for each package and a separate list of real red flags, if any were found.
EOF
}

write_readme_for_bundle() {
  local out="$1"

  cat > "$out" <<'EOF'
# AUR Update Audit Bundle

This bundle was generated by `aur-update-audit.sh`.

It is intended to help a human or AI reviewer inspect pending AUR package updates without building or installing anything.

## Important files

### `SUMMARY.tsv`

A summary table containing:

- package name
- package base
- installed version
- target version
- raw update line
- matched AUR commit for the installed version
- current AUR HEAD
- red-flag hit counts

### `AUR_UPDATES_RAW.txt`

Raw update list from `paru -Qua`, `yay -Qua`, or manual package mode.

### `<package>/META.txt`

Basic package metadata for the audit.

### `<package>/AUR_RPC_INFO.json`

AUR RPC metadata.

### `<package>/current-tree/`

Current AUR repository tree without `.git`.

### `<package>/installed-tree/`

AUR repository tree at the commit that appears to match the currently installed version, if found.

### `<package>/current-files/`

Current `PKGBUILD`, `.SRCINFO`, and `*.install` files.

### `<package>/AUR_PKGBUILD_SRCINFO_DIFF.patch`

The most important diff: current `PKGBUILD` and `.SRCINFO` versus the recipe matching the installed version.

### `<package>/AUR_INSTALL_FILES_DIFF.patch`

Diff for `*.install` files, if any exist.

### `<package>/AUR_FULL_DIFF_FROM_INSTALLED.patch`

Full AUR repository diff from the installed-version recipe to current AUR HEAD.

### `<package>/AUR_LAST_20_COMMITS.patch`

Fallback patch file used when the script cannot identify the installed-version commit.

### `<package>/SOURCE_AND_SUMS_CURRENT.txt`

Extracted source URLs, checksums, valid PGP keys, and packaging function names from the current tree.

### `<package>/SOURCE_AND_SUMS_INSTALLED.txt`

Same as above for the installed-version tree, if available.

### `<package>/REDFLAGS_CURRENT_TREE.txt`

Automatic grep hits for potentially risky commands or terms in the current tree.

This is not a malware verdict by itself. It is only a list of places worth checking.

### `<package>/REDFLAGS_FULL_DIFF.txt`

Automatic grep hits inside the full diff.

### `<package>/local-pacman/`

Local pacman metadata for the installed package.

### `<package>/upstream-git/`

For VCS packages, this contains an attempted upstream git log/diff summary from the commit hash detected in the installed package version.

### `<package>/AUR_REPO_FULL_HISTORY.bundle`

A Git bundle containing the full AUR repository history.

To inspect it:

```bash
git clone AUR_REPO_FULL_HISTORY.bundle repo
```

## AI review prompt

See `AUDIT_PROMPT.md`.
EOF
}

write_top_level_readme() {
  local out="$1"

  cat > "$out" <<'EOF'
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
- normal CVE/build-fix patches

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

## License

No license is included by default. Add one before publishing if you want others to reuse or contribute.
EOF
}

parse_args "$@"

need_cmd git
need_cmd pacman
need_cmd curl
need_cmd tar
need_cmd sed
need_cmd awk
need_cmd grep

if [[ ${#MANUAL_PACKAGES[@]} -eq 0 ]]; then
  select_update_manager
fi

mkdir -p "$OUTPUT_PARENT" || die "cannot create output parent: $OUTPUT_PARENT"

STAMP="$(date '+%Y%m%d-%H%M%S')"
WORK="$OUTPUT_PARENT/aur-update-audit-$STAMP"
REPOS="$WORK/repos"
REPORTS="$WORK/reports"
ARCHIVE="$OUTPUT_PARENT/aur-update-audit-$STAMP.tar.gz"

mkdir -p "$REPOS" "$REPORTS"

{
  echo -e "package\tpackage_base\tinstalled_version\ttarget_version\tupdate_line\tmatched_commit\taur_head\tredflags_current\tredflags_diff"
} > "$REPORTS/SUMMARY.tsv"

if [[ ${#MANUAL_PACKAGES[@]} -gt 0 ]]; then
  for pkg in "${MANUAL_PACKAGES[@]}"; do
    installed_ver="$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}' || true)"
    if [[ -n "$installed_ver" ]]; then
      printf '%s %s -> manual-target\n' "$pkg" "$installed_ver"
    else
      printf '%s NOT-INSTALLED -> manual-target\n' "$pkg"
    fi
  done > "$REPORTS/AUR_UPDATES_RAW.txt"
else
  NO_COLOR=1 "$UPDATE_MANAGER" -Qua 2>/dev/null | sed '/^[[:space:]]*$/d' > "$REPORTS/AUR_UPDATES_RAW.txt"
fi

if [[ ! -s "$REPORTS/AUR_UPDATES_RAW.txt" ]]; then
  cat > "$REPORTS/NO_UPDATES.txt" <<'EOF'
No AUR updates were detected, or no manual targets were provided.
EOF

  write_readme_for_bundle "$REPORTS/README.md"
  write_ai_prompt "$REPORTS/AUDIT_PROMPT.md"

  tar -C "$WORK" -czf "$ARCHIVE" reports
  info "No AUR updates detected."
  info "Created informational archive:"
  info "$ARCHIVE"
  exit 0
fi

while IFS= read -r update_line; do
  [[ -z "$update_line" ]] && continue

  package="$(awk '{print $1}' <<< "$update_line")"
  target_version="$(sed -E 's/^.* -> //' <<< "$update_line")"

  info ""
  info "==> $package"

  pkg_report="$REPORTS/$package"
  mkdir -p "$pkg_report" "$pkg_report/current-files" "$pkg_report/local-pacman"

  printf '%s\n' "$update_line" > "$pkg_report/UPDATE_LINE.txt"

  installed_ver="$(pacman -Q "$package" 2>/dev/null | awk '{print $2}' || true)"

  if [[ -z "$installed_ver" ]]; then
    {
      echo "Package: $package"
      echo "Update line: $update_line"
      echo "Installed version: NOT INSTALLED"
      echo "Status: skipped"
    } > "$pkg_report/META.txt"

    echo -e "$package\tUNKNOWN\tNOT-INSTALLED\t$target_version\t$update_line\tSKIPPED\tSKIPPED\t0\t0" >> "$REPORTS/SUMMARY.tsv"
    info "  not installed, skipping"
    continue
  fi

  pacman -Qi "$package" > "$pkg_report/local-pacman/pacman-Qi.txt" 2>&1 || true
  pacman -Ql "$package" > "$pkg_report/local-pacman/pacman-Ql.txt" 2>&1 || true
  pacman -Qii "$package" > "$pkg_report/local-pacman/pacman-Qii.txt" 2>&1 || true

  mapfile -t split_ver < <(split_arch_version "$installed_ver")
  installed_pkgver="${split_ver[0]}"
  installed_pkgrel="${split_ver[1]}"

  aur_rpc_json="$pkg_report/AUR_RPC_INFO.json"
  pkgbase="$(resolve_pkgbase "$package" "$aur_rpc_json")"

  repo="$REPOS/$pkgbase"

  {
    echo "Package: $package"
    echo "PackageBase: $pkgbase"
    echo "Update line: $update_line"
    echo "Installed version: $installed_ver"
    echo "Installed pkgver: $installed_pkgver"
    echo "Installed pkgrel: $installed_pkgrel"
    echo "Target version: $target_version"
    echo "Audit time: $(date --iso-8601=seconds)"
    echo "Update manager: ${UPDATE_MANAGER:-manual}"
  } > "$pkg_report/META.txt"

  if ! git clone "$AUR_GIT_BASE/$pkgbase.git" "$repo" > "$pkg_report/GIT_CLONE.log" 2>&1; then
    echo "FAILED TO CLONE AUR REPO FOR PACKAGEBASE: $pkgbase" >> "$pkg_report/META.txt"

    if [[ "$pkgbase" != "$package" ]]; then
      repo="$REPOS/$package"
      if git clone "$AUR_GIT_BASE/$package.git" "$repo" >> "$pkg_report/GIT_CLONE.log" 2>&1; then
        pkgbase="$package"
        echo "Fallback clone succeeded with package name: $package" >> "$pkg_report/META.txt"
      else
        echo "FAILED FALLBACK CLONE TOO" >> "$pkg_report/META.txt"
        echo -e "$package\t$pkgbase\t$installed_ver\t$target_version\t$update_line\tCLONE-FAILED\tCLONE-FAILED\t0\t0" >> "$REPORTS/SUMMARY.tsv"
        info "  failed to clone"
        continue
      fi
    else
      echo -e "$package\t$pkgbase\t$installed_ver\t$target_version\t$update_line\tCLONE-FAILED\tCLONE-FAILED\t0\t0" >> "$REPORTS/SUMMARY.tsv"
      info "  failed to clone"
      continue
    fi
  fi

  head_commit="$(git -C "$repo" rev-parse HEAD)"
  echo "AUR HEAD: $head_commit" >> "$pkg_report/META.txt"

  if [[ "$INCLUDE_BUNDLES" -eq 1 ]]; then
    git -C "$repo" bundle create "$pkg_report/AUR_REPO_FULL_HISTORY.bundle" --all \
      > "$pkg_report/AUR_BUNDLE.log" 2>&1 || true
  fi

  copy_tree_without_git "$repo" "$pkg_report/current-tree"

  [[ -f "$repo/PKGBUILD" ]] && cp "$repo/PKGBUILD" "$pkg_report/current-files/PKGBUILD"
  [[ -f "$repo/.SRCINFO" ]] && cp "$repo/.SRCINFO" "$pkg_report/current-files/.SRCINFO"

  for install_file in "$repo"/*.install; do
    [[ -f "$install_file" ]] && cp "$install_file" "$pkg_report/current-files/"
  done

  git -C "$repo" status --short > "$pkg_report/AUR_STATUS.txt"
  git -C "$repo" remote -v > "$pkg_report/AUR_REMOTE.txt"
  git -C "$repo" log --date=iso --pretty=fuller --stat -n 50 \
    > "$pkg_report/AUR_COMMIT_LOG_LAST_50.txt"
  git -C "$repo" log --oneline --decorate -n 100 \
    > "$pkg_report/AUR_COMMIT_LOG_ONELINE_LAST_100.txt"

  source_and_sums_extract "$pkg_report/current-tree" "$pkg_report/SOURCE_AND_SUMS_CURRENT.txt"
  redflag_scan "$pkg_report/current-tree" "$pkg_report/REDFLAGS_CURRENT_TREE.txt"

  base_commit="$(find_matching_aur_commit "$repo" "$installed_pkgver" "$installed_pkgrel" || true)"

  if [[ -n "$base_commit" ]]; then
    echo "Matched installed AUR commit: $base_commit" >> "$pkg_report/META.txt"

    archive_tree_from_commit "$repo" "$base_commit" "$pkg_report/installed-tree"

    source_and_sums_extract "$pkg_report/installed-tree" "$pkg_report/SOURCE_AND_SUMS_INSTALLED.txt"
    redflag_scan "$pkg_report/installed-tree" "$pkg_report/REDFLAGS_INSTALLED_TREE.txt"

    git -C "$repo" diff --stat "$base_commit..HEAD" \
      > "$pkg_report/AUR_DIFF_STAT_FROM_INSTALLED.txt"

    git -C "$repo" diff --name-status "$base_commit..HEAD" \
      > "$pkg_report/AUR_DIFF_FILES_FROM_INSTALLED.txt"

    git -C "$repo" diff --find-renames "$base_commit..HEAD" -- . \
      > "$pkg_report/AUR_FULL_DIFF_FROM_INSTALLED.patch"

    git -C "$repo" diff --find-renames "$base_commit..HEAD" -- PKGBUILD .SRCINFO \
      > "$pkg_report/AUR_PKGBUILD_SRCINFO_DIFF.patch"

    git -C "$repo" diff --find-renames "$base_commit..HEAD" -- '*.install' \
      > "$pkg_report/AUR_INSTALL_FILES_DIFF.patch"

    redflag_scan "$pkg_report/AUR_FULL_DIFF_FROM_INSTALLED.patch" "$pkg_report/REDFLAGS_FULL_DIFF.txt"
  else
    echo "Matched installed AUR commit: NOT FOUND" >> "$pkg_report/META.txt"
    echo "Could not find an exact AUR commit for the installed version." \
      > "$pkg_report/AUR_MATCH_WARNING.txt"

    git -C "$repo" show --stat --patch --find-renames -n 20 \
      > "$pkg_report/AUR_LAST_20_COMMITS.patch"

    redflag_scan "$pkg_report/AUR_LAST_20_COMMITS.patch" "$pkg_report/REDFLAGS_LAST_20_COMMITS.txt"
  fi

  if [[ "$INCLUDE_UPSTREAM_GIT" -eq 1 ]]; then
    git_urls="$(
      grep -RhoE "git\+https?://[^\"' )]+" "$repo/PKGBUILD" "$repo/.SRCINFO" 2>/dev/null \
        | sort -u || true
    )"

    if [[ -n "$git_urls" ]]; then
      mkdir -p "$pkg_report/upstream-git"
      printf '%s\n' "$git_urls" > "$pkg_report/UPSTREAM_GIT_URLS_RAW.txt"

      hashes="$(extract_possible_hashes "$installed_ver")"

      while IFS= read -r raw_url; do
        [[ -z "$raw_url" ]] && continue

        clean_url="$(normalize_git_url "$raw_url")"
        safe_name="$(safe_filename "$clean_url")"
        updir="$REPOS/$pkgbase-upstream-$safe_name"
        upreport="$pkg_report/upstream-git/$safe_name"

        mkdir -p "$upreport"

        {
          echo "URL: $clean_url"
          echo "Installed version: $installed_ver"
          echo "Possible hashes from installed version:"
          printf '%s\n' "$hashes"
        } > "$upreport/META.txt"

        if ! git clone --filter=blob:none --no-checkout "$clean_url" "$updir" > "$upreport/CLONE.log" 2>&1; then
          echo "FAILED TO CLONE UPSTREAM" >> "$upreport/META.txt"
          continue
        fi

        git -C "$updir" remote -v > "$upreport/REMOTE.txt"
        git -C "$updir" branch -r > "$upreport/REMOTE_BRANCHES.txt"
        git -C "$updir" log --oneline --decorate -n 120 > "$upreport/UPSTREAM_HEAD_LOG_LAST_120.txt"

        if [[ -n "$hashes" ]]; then
          while IFS= read -r hash; do
            [[ -z "$hash" ]] && continue

            echo "Trying installed hash: $hash" >> "$upreport/META.txt"

            if git -C "$updir" cat-file -e "$hash^{commit}" 2>/dev/null; then
              git -C "$updir" log --oneline --decorate "$hash..HEAD" \
                > "$upreport/UPSTREAM_LOG_FROM_INSTALLED_HASH_$hash.txt"

              git -C "$updir" diff --stat "$hash..HEAD" \
                > "$upreport/UPSTREAM_DIFF_STAT_FROM_INSTALLED_HASH_$hash.txt"

              git -C "$updir" diff --name-status "$hash..HEAD" \
                > "$upreport/UPSTREAM_DIFF_FILES_FROM_INSTALLED_HASH_$hash.txt"
            else
              echo "Hash not found in upstream clone: $hash" >> "$upreport/META.txt"
            fi
          done <<< "$hashes"
        else
          echo "No git hash detected in installed version: $installed_ver" >> "$upreport/META.txt"
        fi
      done <<< "$git_urls"
    fi
  fi

  redflags_current="$(wc -l < "$pkg_report/REDFLAGS_CURRENT_TREE.txt" 2>/dev/null || echo 0)"

  if [[ -f "$pkg_report/REDFLAGS_FULL_DIFF.txt" ]]; then
    redflags_diff="$(wc -l < "$pkg_report/REDFLAGS_FULL_DIFF.txt" 2>/dev/null || echo 0)"
  elif [[ -f "$pkg_report/REDFLAGS_LAST_20_COMMITS.txt" ]]; then
    redflags_diff="$(wc -l < "$pkg_report/REDFLAGS_LAST_20_COMMITS.txt" 2>/dev/null || echo 0)"
  else
    redflags_diff="0"
  fi

  echo -e "$package\t$pkgbase\t$installed_ver\t$target_version\t$update_line\t${base_commit:-NOT-FOUND}\t$head_commit\t$redflags_current\t$redflags_diff" \
    >> "$REPORTS/SUMMARY.tsv"

  info "  done"
done < "$REPORTS/AUR_UPDATES_RAW.txt"

write_readme_for_bundle "$REPORTS/README.md"
write_ai_prompt "$REPORTS/AUDIT_PROMPT.md"

tar -C "$WORK" -czf "$ARCHIVE" reports

info ""
info "Done:"
info "$ARCHIVE"
info ""
info "The bundle also contains an AI review prompt:"
info "reports/AUDIT_PROMPT.md"
