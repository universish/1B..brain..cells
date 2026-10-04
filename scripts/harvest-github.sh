#!/usr/bin/env bash
# ==============================================================================
# GitHub Releases Harvester Worker Script
# Depo: universish/1B..brain..cells (AGPLv3)
# ==============================================================================
set -u

OUTPUT_DB="${1:-shards/github_shard.db}"
mkdir -p "$(dirname "$OUTPUT_DB")"

echo "=== GitHub Linux Uygulamaları Tarayıcısı Başlatıldı ==="
echo "Hedef Veritabanı: $OUTPUT_DB"

# 1. SQLite Şema Başlatma (WAL Modu)
sqlite3 "$OUTPUT_DB" << 'EOF'
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS applications (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    homepage TEXT,
    source_repo TEXT NOT NULL,
    forge_type TEXT NOT NULL,
    license TEXT,
    stars INTEGER DEFAULT 0,
    created_at INTEGER,
    updated_at INTEGER
);

CREATE TABLE IF NOT EXISTS releases (
    id TEXT PRIMARY KEY,
    app_id TEXT NOT NULL,
    tag_name TEXT NOT NULL,
    published_at INTEGER NOT NULL,
    changelog TEXT,
    FOREIGN KEY(app_id) REFERENCES applications(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS assets (
    id TEXT PRIMARY KEY,
    release_id TEXT NOT NULL,
    file_name TEXT NOT NULL,
    download_url TEXT NOT NULL,
    file_size INTEGER,
    sha256 TEXT,
    cpu_arch TEXT NOT NULL,
    package_type TEXT NOT NULL,
    interface_type TEXT NOT NULL,
    gui_toolkit TEXT,
    FOREIGN KEY(release_id) REFERENCES releases(id) ON DELETE CASCADE
);
EOF

# 2. Taranacak Popüler Linux Uygulamaları Listesi
# Format: repo|interface_type|gui_toolkit
REPOS_CONFIG=(
  "BurntSushi/ripgrep|cli|none"
  "sharkdp/fd|cli|none"
  "sharkdp/bat|cli|none"
  "eza-community/eza|cli|none"
  "dandavison/delta|cli|none"
  "starship/starship|cli|none"
  "bootandy/dust|cli|none"
  "ducaale/xh|cli|none"
  "junegunn/fzf|cli|none"
  "casey/just|cli|none"
  "typst/typst|cli|none"
  "astral-sh/uv|cli|none"
  "astral-sh/ruff|cli|none"
  "fastfetch-cli/fastfetch|cli|none"
  "cli/cli|cli|none"
  "denoland/deno|cli|none"
  "nushell/nushell|cli|none"
  "bottom-rs/bottom|tui|none"
  "zellij-org/zellij|tui|none"
  "helix-editor/helix|tui|none"
  "neovim/neovim|tui|none"
  "jesseduffield/lazygit|tui|none"
  "jesseduffield/lazydocker|tui|none"
  "charmbracelet/glow|tui|none"
  "charmbracelet/gum|tui|none"
  "alacritty/alacritty|gui|none"
  "wez/wezterm|gui|none"
  "lapce/lapce|gui|none"
  "tauri-apps/tauri|cli|tauri"
)

# API Token Yetkilendirmesi (Varsa)
AUTH_HEADER=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH_HEADER=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

COUNT=0
PUB_AT=$(date +%s)

for item in "${REPOS_CONFIG[@]}"; do
  IFS="|" read -r repo default_ui default_toolkit <<< "$item"
  echo -n "[$(date +'%H:%M:%S')] Taranıyor: $repo ... "

  RESP=$(curl -s --connect-timeout 10 -H "User-Agent: OrangeCat-Harvester/1.0" -H "Accept: application/vnd.github.v3+json" "${AUTH_HEADER[@]}" "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null || true)

  TAG=$(echo "$RESP" | jq -r '.tag_name // empty' 2>/dev/null || true)
  if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
    echo "Sürüm bulunamadı veya kota sınırı."
    continue
  fi

  NAME=$(basename "$repo")
  APP_ID="github:$repo"
  DESC=$(echo "$RESP" | jq -r '(.name // "")[0:150]' 2>/dev/null | tr -d '\000-\037' | sed "s/'/''/g")
  BODY=$(echo "$RESP" | jq -r '(.body // "")[0:200]' 2>/dev/null | tr -d '\000-\037' | sed "s/'/''/g")
  REL_ID="${APP_ID}:${TAG}"

  # Uygulama ve Sürüm Kaydı
  sqlite3 "$OUTPUT_DB" "INSERT OR REPLACE INTO applications (id, name, description, source_repo, forge_type, updated_at) VALUES ('$APP_ID', '$NAME', '$DESC', 'https://github.com/$repo', 'github', $PUB_AT);" 2>/dev/null || true
  sqlite3 "$OUTPUT_DB" "INSERT OR REPLACE INTO releases (id, app_id, tag_name, published_at, changelog) VALUES ('$REL_ID', '$APP_ID', '$TAG', $PUB_AT, '$BODY');" 2>/dev/null || true

  # Varlıkların Ayrıştırılması
  echo "$RESP" | jq -c '.assets[]?' 2>/dev/null | while read -r asset; do
    [ -z "$asset" ] && continue
    FNAME=$(echo "$asset" | jq -r '.name // empty' 2>/dev/null || true)
    [ -z "$FNAME" ] && continue
    URL=$(echo "$asset" | jq -r '.browser_download_url // empty' 2>/dev/null || true)
    SIZE=$(echo "$asset" | jq -r '.size // 0' 2>/dev/null || true)
    ASSET_ID="${REL_ID}:${FNAME}"

    # Mimari Sınıflandırma
    ARCH="x86_64"
    if [[ "$FNAME" =~ (aarch64|arm64) ]]; then
      ARCH="aarch64"
    elif [[ "$FNAME" =~ (armv7|armhf) ]]; then
      ARCH="armv7"
    elif [[ "$FNAME" =~ (riscv64) ]]; then
      ARCH="riscv64"
    elif [[ "$FNAME" =~ (i686|x86_32|i386) ]]; then
      ARCH="i686"
    fi

    # Paket Türü
    PKG="binary"
    if [[ "$FNAME" =~ \.tar\.(gz|xz|zst|bz2)$ ]]; then
      PKG="tarball"
    elif [[ "$FNAME" =~ \.AppImage$ ]]; then
      PKG="appimage"
    elif [[ "$FNAME" =~ \.deb$ ]]; then
      PKG="deb"
    elif [[ "$FNAME" =~ \.rpm$ ]]; then
      PKG="rpm"
    elif [[ "$FNAME" =~ \.zip$ ]]; then
      PKG="zip"
    fi

    # Yalnızca Linux ile uyumlu varlıkları filtrele (Windows .exe, .msi, macOS .dmg hariç)
    if [[ "$FNAME" =~ \.(exe|msi|dmg|pkg)$ ]] || [[ "$FNAME" =~ (windows|apple|darwin) ]]; then
      continue
    fi

    SAFE_FNAME=$(echo "$FNAME" | tr -d '\000-\037' | sed "s/'/''/g")
    SAFE_URL=$(echo "$URL" | tr -d '\000-\037' | sed "s/'/''/g")

    sqlite3 "$OUTPUT_DB" "INSERT OR REPLACE INTO assets (id, release_id, file_name, download_url, file_size, cpu_arch, package_type, interface_type, gui_toolkit) VALUES ('$ASSET_ID', '$REL_ID', '$SAFE_FNAME', '$SAFE_URL', $SIZE, '$ARCH', '$PKG', '$default_ui', '$default_toolkit');" 2>/dev/null || true
  done

  COUNT=$((COUNT + 1))
  echo "Tamamlandı ($TAG)"
done

sqlite3 "$OUTPUT_DB" "VACUUM;" 2>/dev/null || true
echo "=== Tarama Tamamlandı. Toplam Kaydedilen Uygulama: $COUNT ==="
sqlite3 "$OUTPUT_DB" "SELECT count(*) AS app_count FROM applications;"
sqlite3 "$OUTPUT_DB" "SELECT count(*) AS asset_count FROM assets;"
