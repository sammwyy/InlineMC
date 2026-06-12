#!/usr/bin/env bash
set -euo pipefail

# Minimal local-first Minecraft launcher.

API="${API:-http://localhost:3000/v1/plan.txt}"

MC_HOME="${MC_HOME:-$HOME/.minecraft}"
CACHE_DIR="${CACHE_DIR:-$MC_HOME/cache}"
PLAN_DIR="${PLAN_DIR:-$CACHE_DIR/inlineversions}"
LAST_USERNAME_FILE="$CACHE_DIR/last_username"
LAST_VERSION_FILE="$CACHE_DIR/last_version"

OS_NAME="${OS_NAME:-linux}"
ARCH="${ARCH:-x64}"

UUID="${UUID:-00000000-0000-0000-0000-000000000000}"
ACCESS_TOKEN="${ACCESS_TOKEN:-0}"
USER_TYPE="${USER_TYPE:-legacy}"

read_cached_value() {
  local file="$1"
  local value=""

  if [ -f "$file" ]; then
    IFS= read -r value < "$file"
    printf '%s' "$value"
  fi

  return 0
}

prompt_value() {
  local label="$1"
  local cached="$2"
  local fallback="$3"
  local input=""
  local value=""

  while [ -z "$value" ]; do
    if [ -n "$cached" ]; then
      read -r -p "$label [$cached]: " input
      value="${input:-$cached}"
    elif [ -n "$fallback" ]; then
      read -r -p "$label [$fallback]: " input
      value="${input:-$fallback}"
    else
      read -r -p "$label: " input
      value="$input"
    fi

    if [ -z "$value" ]; then
      echo "$label is required." >&2
    fi
  done

  printf '%s' "$value"
}

mkdir -p "$MC_HOME" "$CACHE_DIR" "$PLAN_DIR"

LAST_USERNAME="$(read_cached_value "$LAST_USERNAME_FILE")"
LAST_VERSION="$(read_cached_value "$LAST_VERSION_FILE")"

echo "===================="
echo "      InlineMC"
echo "===================="

PLAYER_NAME="$(prompt_value "username" "$LAST_USERNAME" "")"
REQUESTED_VERSION="$(prompt_value "version" "$LAST_VERSION" "1.21.1")"

printf '%s\n' "$PLAYER_NAME" > "$LAST_USERNAME_FILE"
printf '%s\n' "$REQUESTED_VERSION" > "$LAST_VERSION_FILE"

VERSION="$REQUESTED_VERSION"
PLAN_FILE="$PLAN_DIR/${REQUESTED_VERSION}_response.txt"

if [ ! -f "$PLAN_FILE" ]; then
  echo "Downloading launch plan..."
  curl -L -o "$PLAN_FILE" "$API?version=$REQUESTED_VERSION&os=$OS_NAME&arch=$ARCH"
fi

MAIN_CLASS=""
ASSET_INDEX_ID=""
VERSION_TYPE="release"
CLASSPATH=""
JVM_ARGS=()
GAME_ARGS=()
NATIVES_DIR="$MC_HOME/versions/$VERSION/natives"
SKIP_NEXT_GAME_ARG=0

verify_sha1() {
  local file="$1"
  local expected="$2"

  [ -z "$expected" ] && return 0

  local actual
  actual="$(sha1sum "$file" | awk '{print $1}')"

  [ "$actual" = "$expected" ]
}

download_file() {
  local rel_path="$1"
  local sha1="$2"
  local url="$3"
  local out="$MC_HOME/$rel_path"

  if [ -f "$out" ]; then
    if verify_sha1 "$out" "$sha1"; then
      return 0
    fi

    echo "Hash mismatch, redownloading: $rel_path"
    rm -f "$out"
  fi

  mkdir -p "$(dirname "$out")"

  echo "Downloading $rel_path"
  curl -L -o "$out" "$url"

  if ! verify_sha1 "$out" "$sha1"; then
    echo "Failed SHA1 verification: $rel_path"
    exit 1
  fi
}

extract_native() {
  local rel_path="$1"
  local extract_rel="$2"
  local src="$MC_HOME/$rel_path"
  local dst="$MC_HOME/$extract_rel"

  mkdir -p "$dst"
  unzip -oq "$src" -d "$dst"
}

replace_vars() {
  local value="$1"

  value="${value//'${natives_directory}'/$NATIVES_DIR}"
  value="${value//'${launcher_name}'/inlinemc}"
  value="${value//'${launcher_version}'/0.1}"
  value="${value//'${classpath}'/$CLASSPATH}"

  value="${value//'${auth_player_name}'/$PLAYER_NAME}"
  value="${value//'${version_name}'/$VERSION}"
  value="${value//'${game_directory}'/$MC_HOME}"
  value="${value//'${assets_root}'/$MC_HOME/assets}"
  value="${value//'${assets_index_name}'/$ASSET_INDEX_ID}"
  value="${value//'${auth_uuid}'/$UUID}"
  value="${value//'${auth_access_token}'/$ACCESS_TOKEN}"
  value="${value//'${user_type}'/$USER_TYPE}"
  value="${value//'${version_type}'/$VERSION_TYPE}"

  printf '%s' "$value"
}

while IFS='|' read -r kind p1 p2 p3 p4 p5 rest; do
  case "$kind" in
    ""|\#*) ;;

    VERSION)
      VERSION="$p1"
      NATIVES_DIR="$MC_HOME/versions/$VERSION/natives"
      ;;

    VERSION_TYPE)
      VERSION_TYPE="$p1"
      ;;

    MAIN_CLASS)
      MAIN_CLASS="$p1"
      ;;

    ASSET_INDEX_ID)
      ASSET_INDEX_ID="$p1"
      ;;

    CLIENT|LIBRARY|ASSET_INDEX|ASSET)
      download_file "$p1" "$p2" "$p3"
      ;;

    NATIVE)
      download_file "$p1" "$p2" "$p3"
      extract_native "$p1" "$p5"
      ;;

    CLASSPATH)
      if [ -z "$CLASSPATH" ]; then
        CLASSPATH="$MC_HOME/$p1"
      else
        CLASSPATH="$CLASSPATH:$MC_HOME/$p1"
      fi
      ;;

    JVM_ARG)
      # We pass classpath explicitly.
      if [ "$p1" != "-cp" ] && [ "$p1" != '${classpath}' ]; then
        JVM_ARGS+=("$(replace_vars "$p1")")
      fi
      ;;

    GAME_ARG)
      if [ "$SKIP_NEXT_GAME_ARG" -eq 1 ]; then
        SKIP_NEXT_GAME_ARG=0
      elif [ "$p1" = "--demo" ]; then
        :
      elif [ "$p1" = "--width" ] || [ "$p1" = "--height" ]; then
        SKIP_NEXT_GAME_ARG=1
      elif [ "$p1" = "--quickPlayPath" ] \
        || [ "$p1" = "--quickPlaySingleplayer" ] \
        || [ "$p1" = "--quickPlayMultiplayer" ] \
        || [ "$p1" = "--quickPlayRealms" ]; then
        SKIP_NEXT_GAME_ARG=1
      else
        GAME_ARGS+=("$(replace_vars "$p1")")
      fi
      ;;

    OFFLINE_DEFAULT)
      ;;
  esac
done < "$PLAN_FILE"

if [ -z "$MAIN_CLASS" ]; then
  echo "Missing MAIN_CLASS."
  exit 1
fi

if [ -z "$ASSET_INDEX_ID" ]; then
  echo "Missing ASSET_INDEX_ID."
  exit 1
fi

echo "Launching Minecraft $VERSION..."

exec java \
  "${JVM_ARGS[@]}" \
  -cp "$CLASSPATH" \
  "$MAIN_CLASS" \
  "${GAME_ARGS[@]}"
