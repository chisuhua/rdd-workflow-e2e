#!/usr/bin/env bash
# install_testbed.sh — bootstrap rdd-workflow installation for the test bed
#
# Idempotent. Run this on a fresh CI runner before bats:
#   ./install_testbed.sh
#
# Modes:
#   --clone    Clone rdd-workflow from GitHub (default if no local install)
#   --symlink  Use local rdd-workflow checkout (default if found)
#   --uninstall Remove the global install (for cleanup)
#   --status   Show current installation status

set -euo pipefail

RDD_REPO="${RDD_REPO:-chisuhua/rdd-workflow}"
INSTALL_DIR="$HOME/.agents/skills/rdd-workflow"
MODE="auto"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clone) MODE="clone"; shift ;;
        --symlink) MODE="symlink"; shift ;;
        --uninstall) MODE="uninstall"; shift ;;
        --status) MODE="status"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--clone|--symlink|--uninstall|--status]

Bootstrap rdd-workflow for the rdd-workflow-e2e test bed.

Modes (default: auto-detect):
  --clone      Git clone chisuhua/rdd-workflow to a temp dir and global-install it
  --symlink    Symlink \$REPO_ROOT/../rdd-workflow to ~/.agents/skills/rdd-workflow
  --uninstall  Remove the global install (cleanup for CI)
  --status     Show current installation status

Env vars:
  RDD_REPO     GitHub repo (default: chisuhua/rdd-workflow)
EOF
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Auto-detect mode
if [[ "$MODE" == "auto" ]]; then
    if [[ -L "$INSTALL_DIR" ]] || [[ -d "$INSTALL_DIR" ]]; then
        MODE="status"
    elif [[ -d "$REPO_ROOT/../rdd-workflow/.git" ]] || [[ -d "$REPO_ROOT/../rdd-workflow/_lib" ]]; then
        MODE="symlink"
    else
        MODE="clone"
    fi
fi

case "$MODE" in
    clone)
        echo "▶ Cloning $RDD_REPO ..."
        WORK_DIR="$(mktemp -d -t rdd-workflow-XXXXXX)"
        git clone --depth 1 "https://github.com/${RDD_REPO}.git" "$WORK_DIR"
        cd "$WORK_DIR"
        bash install.sh --global
        echo "✅ Installed from $WORK_DIR"
        ;;

    symlink)
        SOURCE="$(cd "$REPO_ROOT/.." && pwd)/rdd-workflow"
        if [[ ! -d "$SOURCE/_lib" ]]; then
            echo "❌ No rdd-workflow checkout at $SOURCE" >&2
            exit 1
        fi
        echo "▶ Symlinking $SOURCE → $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
        ln -s "$SOURCE" "$INSTALL_DIR"
        echo "✅ Symlinked"
        ;;

    uninstall)
        echo "▶ Removing $INSTALL_DIR"
        if [[ -L "$INSTALL_DIR" ]]; then
            rm "$INSTALL_DIR"
        elif [[ -d "$INSTALL_DIR" ]]; then
            rm -rf "$INSTALL_DIR"
        fi
        # Also remove rddf CLI wrapper
        if [[ -f "$HOME/.local/bin/rddf" ]]; then
            rm "$HOME/.local/bin/rddf"
        fi
        echo "✅ Uninstalled"
        ;;

    status)
        echo "▶ rdd-workflow installation status:"
        if [[ -L "$INSTALL_DIR" ]]; then
            echo "  $INSTALL_DIR → $(readlink "$INSTALL_DIR")"
        elif [[ -d "$INSTALL_DIR" ]]; then
            echo "  $INSTALL_DIR (directory, not symlink)"
        else
            echo "  $INSTALL_DIR: NOT INSTALLED"
        fi
        if command -v rddf >/dev/null 2>&1; then
            echo "  rddf CLI: $(which rddf)"
        else
            echo "  rddf CLI: NOT in PATH"
        fi
        ;;
esac