# homebrew-upgrade-mature
![Homebrew](https://img.shields.io/badge/homebrew-command-orange)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

A Homebrew command extension that delays upgrades of recently modified formulae.

Install via Homebrew tap:
`brew tap jhoopmann/upgrade-mature`

Usage: \
`brew upgrade-mature` \
`brew upgrade-mature --greedy` \
`brew upgrade-mature --no-ask` \
`brew upgrade-mature <package> --force` 

The command checks the commit date of outdated formula and only allows
upgrades if the latest commit affecting the formula is older than the
configured age threshold. This provides a more conservative upgrade strategy
and helps avoid immediately installing newly modified formulae.
---

## 🚀 Features
- 🧠 Commit-age based upgrade decisions
- 🕒 Configurable safety window (`BREW_UPGRADE_MATURE_THRESHOLD`)
- 📦 Works with `brew upgrade-mature` and `brew upgrade-mature <package>` and partially flags of `brew upgrade`
- ⚠️ Separates matured vs potential risky upgrades
- 🔍 Git-based formula change detection via GitHub GraphQL API
---
## ⚙️ How it works
For each outdated package:
1. Fetch outdated formula/cask list
2. Query GitHub GraphQL API for the latest commit affecting each formula's source file
3. Compare commit date with `BREW_UPGRADE_MATURE_THRESHOLD`
4. Classify package as:
   - **Allowed** → safe to upgrade
   - **Denied** → too recently modified
5. Prompt user before applying upgrades if ask-mode
---

## 📦 Installation

### 1. Tap the repository
```bash
brew tap jhoopmann/upgrade-mature
```

---
## 🧪 Usage

### Basic usage

Upgrade all packages:
```bash
brew upgrade-mature
```

Upgrade specific packages:
```bash
brew upgrade-mature <package> [<package> ...]
```

### Command-line flags

| Flag | Short | Description |
|------|-------|-------------|
| `--dry-run` | `-n` | Show what would be upgraded, but do not actually upgrade anything. |
| `--no-ask` | `--yes` | `-y` | Skip confirmation prompt before upgrading. The default is interactive (ask mode). |
| `--force` | `-f` | Install formulae without checking for previously installed keg-only or non-migrated versions. For casks, overwrites existing files (binaries and symlinks are excluded unless originally from the same cask). |
| `--skip-cask-deps` | | Skip installing cask dependencies. |
| `--greedy` | | Also include casks with `version :latest` and `auto_updates true` casks that would otherwise be skipped. |
| `--greedy-latest` | | Also include casks with `version :latest`. |
| `--greedy-auto-updates` | | Also include `auto_updates true` casks that would otherwise be skipped. |
| `--[no-]binaries` | | Disable or enable linking of helper executables (default: enabled). |
| `--require-sha` | | Require all casks to have a checksum. |
| `--formula` | `--formulae` | Treat all named arguments as formulae. If no named arguments are specified, upgrade only outdated formulae. Conflicts with `--cask`. |
| `--cask` | `--casks` | Treat all named arguments as casks. If no named arguments are specified, upgrade only outdated casks. Conflicts with `--formula`. |

### Examples

Dry run (preview without upgrading):
```bash
brew upgrade-mature --dry-run
```

Upgrade specific packages, skipping confirmation:
```bash
brew upgrade-mature --yes curl wget
```

Force upgrade with greedy mode:
```bash
brew upgrade-mature --greedy --force
```

---

## ⏱ Configuration

`BREW_UPGRADE_MATURE_THRESHOLD`

Defines how old (in days) a formula commit must be before upgrades are allowed.

Default: **7** (7 days)

Examples:

```bash
# 14-day threshold
BREW_UPGRADE_MATURE_THRESHOLD=14 brew upgrade-mature

# 0-day threshold (upgrade everything immediately)
BREW_UPGRADE_MATURE_THRESHOLD=0 brew upgrade-mature whatsapp
```

---

## 📋 Requirements

* Homebrew

--- 

## ⚠️ Limitations

* Formula age is based on Git commit history of tap's default branch for filepath of the Formula, not the package release version

--- 

## 🔍 Example Output

Default 7 days:
```
$ brew upgrade-mature
Found 6 outdated formulas!

Denied:
 codex-cli (...)
 docker-desktop (...)
 spotify (...)
 whatsapp (...)

Allowed:
 ollama (...)
 libjpeg (...)

Confirm installation of allowed packages? (y/n): n
```

---

## 🧠 Philosophy

This tool assumes:

Recently changed Homebrew formulae are more likely to contain regressions.
It introduces a grace period before upgrades are allowed, prioritizing stability over immediacy.

---

## 🛠 License

MIT

---

## 🤝 Contributing

Pull requests are welcome.

--- 

## ⚡ Disclaimer

This tool wraps `brew upgrade` behavior.
Use at your own risk.
