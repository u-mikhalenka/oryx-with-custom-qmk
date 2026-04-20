#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build-local.sh --layout-id ID [options]

Options:
  --layout-id ID        Oryx layout id to fetch and build.
  --geometry NAME       Keyboard geometry. Default: voyager
  --output-dir PATH     Directory for the merged layout and firmware. Default: .local-build
  --image-name NAME     Docker image tag to use for the local QMK builder. Default: qmk-local-builder
  --keep-temp           Preserve temporary worktrees for debugging.
  --help                Show this help text.
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name=$1

  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "Missing required command: $command_name"
  fi
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$SCRIPT_DIR

LAYOUT_ID=
LAYOUT_GEOMETRY=voyager
OUTPUT_DIR=$REPO_ROOT/.local-build
IMAGE_NAME=qmk-local-builder
KEEP_TEMP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --layout-id)
      [[ $# -ge 2 ]] || fail "--layout-id requires a value"
      LAYOUT_ID=$2
      shift 2
      ;;
    --geometry)
      [[ $# -ge 2 ]] || fail "--geometry requires a value"
      LAYOUT_GEOMETRY=$2
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || fail "--output-dir requires a value"
      case "$2" in
        /*) OUTPUT_DIR=$2 ;;
        *) OUTPUT_DIR=$REPO_ROOT/$2 ;;
      esac
      shift 2
      ;;
    --image-name)
      [[ $# -ge 2 ]] || fail "--image-name requires a value"
      IMAGE_NAME=$2
      shift 2
      ;;
    --keep-temp)
      KEEP_TEMP=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$LAYOUT_ID" ]] || fail "--layout-id is required"

require_command git
require_command curl
require_command jq
require_command unzip
require_command docker
require_command mktemp

[[ -d $REPO_ROOT/.git ]] || fail "This script must live at the repository root"
[[ -f $REPO_ROOT/Dockerfile ]] || fail "Dockerfile not found at repository root"

git -C "$REPO_ROOT" rev-parse --verify main >/dev/null 2>&1 || fail "Missing local branch: main"
git -C "$REPO_ROOT" rev-parse --verify oryx >/dev/null 2>&1 || fail "Missing local branch: oryx"

if [[ -n $(git -C "$REPO_ROOT" status --porcelain) ]]; then
  printf 'Warning: repository has uncommitted changes; the build uses the committed tips of the local main and oryx branches.\n' >&2
fi

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oryx-local-build.XXXXXX")
MAIN_WORKTREE=$TEMP_ROOT/main
ORYX_WORKTREE=$TEMP_ROOT/oryx
DOWNLOADED_LAYOUT_DIR=$TEMP_ROOT/downloaded-layout
MAIN_BRANCH=local-build-main-$$-$(date +%s)
ORYX_BRANCH=local-build-oryx-$$-$(date +%s)

cleanup() {
  local exit_code=$?

  set +e

  if [[ $KEEP_TEMP -eq 1 ]]; then
    printf 'Temporary worktrees preserved at: %s\n' "$TEMP_ROOT" >&2
    printf 'Temporary branches preserved: %s %s\n' "$MAIN_BRANCH" "$ORYX_BRANCH" >&2
    exit "$exit_code"
  fi

  git -C "$REPO_ROOT" worktree remove --force "$MAIN_WORKTREE" >/dev/null 2>&1 || true
  git -C "$REPO_ROOT" worktree remove --force "$ORYX_WORKTREE" >/dev/null 2>&1 || true
  git -C "$REPO_ROOT" branch -D "$MAIN_BRANCH" >/dev/null 2>&1 || true
  git -C "$REPO_ROOT" branch -D "$ORYX_BRANCH" >/dev/null 2>&1 || true
  rm -rf "$TEMP_ROOT"

  exit "$exit_code"
}

trap cleanup EXIT

GRAPHQL_QUERY='query getLayout($hashId: String!, $revisionId: String!, $geometry: String) { layout(hashId: $hashId, geometry: $geometry, revisionId: $revisionId) { revision { hashId qmkVersion title } } }'
GRAPHQL_PAYLOAD=$(jq -cn \
  --arg query "$GRAPHQL_QUERY" \
  --arg hashId "$LAYOUT_ID" \
  --arg geometry "$LAYOUT_GEOMETRY" \
  '{query: $query, variables: {hashId: $hashId, geometry: $geometry, revisionId: "latest"}}')

METADATA_RESPONSE=$(curl --fail --silent --show-error --location \
  'https://oryx.zsa.io/graphql' \
  --header 'Content-Type: application/json' \
  --data "$GRAPHQL_PAYLOAD")

DOWNLOAD_HASH_ID=$(jq -r '.data.layout.revision.hashId // empty' <<<"$METADATA_RESPONSE")
FIRMWARE_VERSION=$(jq -r '(.data.layout.revision.qmkVersion // empty) | floor | tostring' <<<"$METADATA_RESPONSE")
CHANGE_DESCRIPTION=$(jq -r '.data.layout.revision.title // empty' <<<"$METADATA_RESPONSE")

[[ -n "$DOWNLOAD_HASH_ID" ]] || fail "Could not resolve the latest Oryx revision for layout $LAYOUT_ID"
[[ -n "$FIRMWARE_VERSION" ]] || fail "Could not determine the QMK firmware version for layout $LAYOUT_ID"

mkdir -p "$DOWNLOADED_LAYOUT_DIR"
SOURCE_ZIP=$TEMP_ROOT/source.zip

printf 'Fetching Oryx layout %s (%s, firmware %s)\n' "$LAYOUT_ID" "$LAYOUT_GEOMETRY" "$FIRMWARE_VERSION"
curl --fail --silent --show-error --location "https://oryx.zsa.io/source/${DOWNLOAD_HASH_ID}" -o "$SOURCE_ZIP"
unzip -oj "$SOURCE_ZIP" '*_source/*' -d "$DOWNLOADED_LAYOUT_DIR" >/dev/null

git -C "$REPO_ROOT" worktree add -b "$MAIN_BRANCH" "$MAIN_WORKTREE" main >/dev/null
git -C "$REPO_ROOT" worktree add -b "$ORYX_BRANCH" "$ORYX_WORKTREE" oryx >/dev/null

rm -rf "$ORYX_WORKTREE/$LAYOUT_ID"
mkdir -p "$ORYX_WORKTREE/$LAYOUT_ID"
cp -R "$DOWNLOADED_LAYOUT_DIR"/. "$ORYX_WORKTREE/$LAYOUT_ID"

git -C "$ORYX_WORKTREE" add "$LAYOUT_ID"
if ! git -C "$ORYX_WORKTREE" diff --cached --quiet; then
  git -C "$ORYX_WORKTREE" -c user.name=local-builder -c user.email=local-builder@localhost \
    commit -m "Sync Oryx export for $LAYOUT_ID" >/dev/null
fi

printf 'Merging Oryx export into custom branch state\n'
git -C "$MAIN_WORKTREE" merge -Xignore-all-space --no-edit "$ORYX_BRANCH" >/dev/null

printf 'Updating qmk_firmware submodule to firmware%s\n' "$FIRMWARE_VERSION"
git -C "$MAIN_WORKTREE" submodule update --init --remote --depth=1 --no-single-branch >/dev/null
git -C "$MAIN_WORKTREE/qmk_firmware" checkout -B "firmware${FIRMWARE_VERSION}" "origin/firmware${FIRMWARE_VERSION}" >/dev/null
git -C "$MAIN_WORKTREE/qmk_firmware" submodule update --init --recursive >/dev/null

if (( FIRMWARE_VERSION >= 24 )); then
  KEYBOARD_DIRECTORY=$MAIN_WORKTREE/qmk_firmware/keyboards/zsa
  MAKE_PREFIX=zsa/
else
  KEYBOARD_DIRECTORY=$MAIN_WORKTREE/qmk_firmware/keyboards
  MAKE_PREFIX=
fi

TARGET_KEYMAP_DIR=$KEYBOARD_DIRECTORY/$LAYOUT_GEOMETRY/keymaps/$LAYOUT_ID
rm -rf "$TARGET_KEYMAP_DIR"
mkdir -p "$(dirname "$TARGET_KEYMAP_DIR")"
cp -R "$MAIN_WORKTREE/$LAYOUT_ID" "$TARGET_KEYMAP_DIR"

printf 'Building Docker image %s\n' "$IMAGE_NAME"
docker build -t "$IMAGE_NAME" "$MAIN_WORKTREE" >/dev/null

printf 'Building firmware inside Docker\n'
docker run --rm \
  -v "$MAIN_WORKTREE/qmk_firmware:/root" \
  "$IMAGE_NAME" \
  /bin/sh -lc "qmk setup zsa/qmk_firmware -b firmware${FIRMWARE_VERSION} -y && make ${MAKE_PREFIX}${LAYOUT_GEOMETRY}:${LAYOUT_ID}"

NORMALIZED_GEOMETRY=${LAYOUT_GEOMETRY//\//_}
BUILT_LAYOUT_FILE=$(find "$MAIN_WORKTREE/qmk_firmware" -maxdepth 1 -type f \( -name "*${NORMALIZED_GEOMETRY}*.bin" -o -name "*${NORMALIZED_GEOMETRY}*.hex" \) | head -n 1)
[[ -n "$BUILT_LAYOUT_FILE" ]] || fail "Build succeeded but no firmware artifact was found"

mkdir -p "$OUTPUT_DIR"
MERGED_LAYOUT_OUTPUT_DIR=$OUTPUT_DIR/${LAYOUT_ID}
rm -rf "$MERGED_LAYOUT_OUTPUT_DIR"
cp -R "$MAIN_WORKTREE/$LAYOUT_ID" "$MERGED_LAYOUT_OUTPUT_DIR"
cp "$BUILT_LAYOUT_FILE" "$OUTPUT_DIR/"

printf 'Build complete.\n'
printf 'Merged layout: %s\n' "$MERGED_LAYOUT_OUTPUT_DIR"
printf 'Firmware: %s\n' "$OUTPUT_DIR/$(basename "$BUILT_LAYOUT_FILE")"
if [[ -n "$CHANGE_DESCRIPTION" ]]; then
  printf 'Oryx revision title: %s\n' "$CHANGE_DESCRIPTION"
fi
