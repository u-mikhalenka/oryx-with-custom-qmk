#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build-local.sh --layout-id ID [options]

Options:
  --layout-id ID        Oryx layout id to fetch and build. Default: X3nL6
  --geometry NAME       Keyboard geometry. Default: voyager
  --output-dir PATH     Directory for the merged layout and firmware. Default: .local-build
  --keep-temp           Preserve per-run downloaded files for debugging.
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

LAYOUT_ID=X3nL6
LAYOUT_GEOMETRY=voyager
OUTPUT_DIR=$REPO_ROOT/.local-build
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
[[ $OSTYPE == darwin* ]] || fail "Local host builds are only supported on macOS."
require_command make

[[ -d $REPO_ROOT/.git ]] || fail "This script must live at the repository root"

git -C "$REPO_ROOT" rev-parse --verify main >/dev/null 2>&1 || fail "Missing local branch: main"
git -C "$REPO_ROOT" rev-parse --verify oryx >/dev/null 2>&1 || fail "Missing local branch: oryx"

if [[ -n $(git -C "$REPO_ROOT" status --porcelain) ]]; then
  printf 'Warning: repository has uncommitted changes; the build uses the committed tips of local main and oryx, and working-copy layout changes are ignored.\n' >&2
fi

if git -C "$REPO_ROOT" worktree list --porcelain | grep -Fxq 'branch refs/heads/oryx'; then
  fail "The local oryx branch is checked out in a worktree. Switch that worktree away from oryx before running this script."
fi

LOCAL_BUILD_ROOT=$REPO_ROOT/.local-build
RUN_ROOT=$LOCAL_BUILD_ROOT/run
QMK_REPO=$LOCAL_BUILD_ROOT/qmk
ORYX_REMOTE_NAME=local-build-oryx
QMK_REMOTE_URL=https://github.com/zsa/qmk_firmware.git

mkdir -p "$LOCAL_BUILD_ROOT"
MAIN_REPO=$RUN_ROOT/main
ORYX_REPO=$RUN_ROOT/oryx
DOWNLOADED_LAYOUT_DIR=$RUN_ROOT/downloaded-layout
SOURCE_ZIP=$RUN_ROOT/source.zip

clone_branch() {
  local repo_path=$1
  local branch_name=$2

  if [[ -e $repo_path ]]; then
    rm -rf "$repo_path"
  fi

  mkdir -p "$(dirname "$repo_path")"
  git clone --branch "$branch_name" "$REPO_ROOT" "$repo_path" >/dev/null
}

ensure_qmk_clone() {
  if [[ -d $QMK_REPO/.git ]] && git -C "$QMK_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return
  fi

  if [[ -e $QMK_REPO ]]; then
    rm -rf "$QMK_REPO"
  fi

  mkdir -p "$LOCAL_BUILD_ROOT"
  git clone --filter=blob:none "$QMK_REMOTE_URL" "$QMK_REPO" >/dev/null
}

sync_qmk_branch() {
  local branch_name="firmware$1"
  local current_branch=
  local local_head=
  local remote_head=

  ensure_qmk_clone
  git -C "$QMK_REPO" remote set-url origin "$QMK_REMOTE_URL"
  git -C "$QMK_REPO" fetch --prune origin "$branch_name" >/dev/null

  current_branch=$(git -C "$QMK_REPO" branch --show-current)
  local_head=$(git -C "$QMK_REPO" rev-parse HEAD)
  remote_head=$(git -C "$QMK_REPO" rev-parse "origin/$branch_name")

  if [[ $current_branch == "$branch_name" && $local_head == "$remote_head" ]]; then
    printf 'Cached ZSA QMK checkout already matches %s; keeping existing worktree for build cache\n' "$branch_name"
    return
  fi

  git -C "$QMK_REPO" checkout -B "$branch_name" "origin/$branch_name" >/dev/null
  git -C "$QMK_REPO" reset --hard "origin/$branch_name" >/dev/null
  git -C "$QMK_REPO" clean -fdx >/dev/null
  git -C "$QMK_REPO" submodule update --init --recursive >/dev/null
}

prepare_run_workspace() {
  rm -rf "$RUN_ROOT"
  mkdir -p "$DOWNLOADED_LAYOUT_DIR"
}

update_local_oryx_branch() {
  local commit_message=$1
  local oryx_head=

  oryx_head=$(git -C "$ORYX_REPO" rev-parse HEAD)
  git -C "$REPO_ROOT" fetch "$ORYX_REPO" "$oryx_head:refs/heads/oryx" >/dev/null

  if [[ -n $commit_message ]]; then
    printf 'Updated local oryx branch: %s\n' "$commit_message"
  else
    printf 'Updated local oryx branch for %s\n' "$LAYOUT_ID"
  fi
}

cleanup() {
  local exit_code=$?

  set +e

  if [[ $KEEP_TEMP -eq 1 ]]; then
    printf 'Per-run files preserved at: %s\n' "$RUN_ROOT" >&2
    printf 'Persistent cached repo: %s\n' "$QMK_REPO" >&2
    exit "$exit_code"
  fi

  rm -rf "$RUN_ROOT"

  exit "$exit_code"
}

trap cleanup EXIT

prepare_run_workspace

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
FIRMWARE_VERSION=$(jq -r '(.data.layout.revision.qmkVersion // empty) | tonumber? | floor | tostring // empty' <<<"$METADATA_RESPONSE")
CHANGE_DESCRIPTION=$(jq -r '.data.layout.revision.title // empty' <<<"$METADATA_RESPONSE")

[[ -n "$DOWNLOAD_HASH_ID" ]] || fail "Could not resolve the latest Oryx revision for layout $LAYOUT_ID"
[[ -n "$FIRMWARE_VERSION" ]] || fail "Could not determine the QMK firmware version for layout $LAYOUT_ID"

printf 'Fetching Oryx layout %s (%s, firmware %s)\n' "$LAYOUT_ID" "$LAYOUT_GEOMETRY" "$FIRMWARE_VERSION"
curl --fail --silent --show-error --location "https://oryx.zsa.io/source/${DOWNLOAD_HASH_ID}" -o "$SOURCE_ZIP"
unzip -oj "$SOURCE_ZIP" '*_source/*' -d "$DOWNLOADED_LAYOUT_DIR" >/dev/null

clone_branch "$MAIN_REPO" main
clone_branch "$ORYX_REPO" oryx

rm -rf "$ORYX_REPO/$LAYOUT_ID"
mkdir -p "$ORYX_REPO/$LAYOUT_ID"
cp -R "$DOWNLOADED_LAYOUT_DIR"/. "$ORYX_REPO/$LAYOUT_ID"

git -C "$ORYX_REPO" add "$LAYOUT_ID"
if ! git -C "$ORYX_REPO" diff --cached --quiet; then
  ORYX_COMMIT_MESSAGE=${CHANGE_DESCRIPTION:-Sync Oryx export for $LAYOUT_ID}
  git -C "$ORYX_REPO" -c user.name=local-builder -c user.email=local-builder@localhost \
    commit -m "$ORYX_COMMIT_MESSAGE" >/dev/null
  update_local_oryx_branch "$ORYX_COMMIT_MESSAGE"
else
  printf 'Local oryx branch already matches the downloaded export for %s\n' "$LAYOUT_ID"
fi

printf 'Merging Oryx export into custom branch state\n'
if git -C "$MAIN_REPO" remote get-url "$ORYX_REMOTE_NAME" >/dev/null 2>&1; then
  git -C "$MAIN_REPO" remote set-url "$ORYX_REMOTE_NAME" "$ORYX_REPO"
else
  git -C "$MAIN_REPO" remote add "$ORYX_REMOTE_NAME" "$ORYX_REPO"
fi
git -C "$MAIN_REPO" fetch "$ORYX_REMOTE_NAME" oryx >/dev/null
git -C "$MAIN_REPO" merge -Xignore-all-space --no-edit "$ORYX_REMOTE_NAME/oryx" >/dev/null

printf 'Updating cached ZSA QMK checkout to firmware%s\n' "$FIRMWARE_VERSION"
sync_qmk_branch "$FIRMWARE_VERSION"

if (( FIRMWARE_VERSION >= 24 )); then
  KEYBOARD_DIRECTORY=$QMK_REPO/keyboards/zsa
  MAKE_PREFIX=zsa/
else
  KEYBOARD_DIRECTORY=$QMK_REPO/keyboards
  MAKE_PREFIX=
fi

TARGET_KEYMAP_DIR=$KEYBOARD_DIRECTORY/$LAYOUT_GEOMETRY/keymaps/$LAYOUT_ID
rm -rf "$TARGET_KEYMAP_DIR"
mkdir -p "$(dirname "$TARGET_KEYMAP_DIR")"
cp -R "$MAIN_REPO/$LAYOUT_ID" "$TARGET_KEYMAP_DIR"

printf 'Building firmware in %s\n' "$QMK_REPO"
(
  cd "$QMK_REPO"
  make "${MAKE_PREFIX}${LAYOUT_GEOMETRY}:${LAYOUT_ID}"
)

NORMALIZED_GEOMETRY=${LAYOUT_GEOMETRY//\//_}
BUILT_LAYOUT_FILE=$(find "$QMK_REPO" -maxdepth 1 -type f \( -name "*${NORMALIZED_GEOMETRY}*.bin" -o -name "*${NORMALIZED_GEOMETRY}*.hex" \) | head -n 1)
[[ -n "$BUILT_LAYOUT_FILE" ]] || fail "Build succeeded but no firmware artifact was found"

mkdir -p "$OUTPUT_DIR"
cp "$BUILT_LAYOUT_FILE" "$OUTPUT_DIR/"

printf 'Build complete.\n'
printf 'Firmware: %s\n' "$OUTPUT_DIR/$(basename "$BUILT_LAYOUT_FILE")"
if [[ -n "$CHANGE_DESCRIPTION" ]]; then
  printf 'Oryx revision title: %s\n' "$CHANGE_DESCRIPTION"
fi
