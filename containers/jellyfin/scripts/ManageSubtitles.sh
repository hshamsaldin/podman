#!/bin/bash
# ManageSubtitles.sh - interactive subtitle importer for Jellyfin.
#
# Run with no arguments:
#     ./ManageSubtitles.sh
# Pick a show (by number), pick a season (or "all"), point it at a subtitle
# .zip/folder. It previews, and on "y" copies each sub beside its episode as
# <video-basename>.<lang>.<ext>, archives a copy in Subtitles/, flattens any
# "Season NN/Season NN", and can trigger a Jellyfin library scan.
#
# Needs python3 (matching) + curl (optional scan). Run on the host.
set -uo pipefail
# load JELLYFIN_API_KEY / JELLYFIN_URL / JELLYFIN_SHOWS from the deploy dir's .env
# (the same .env the Quadlet unit reads, one level up from scripts/). .env is gitignored.
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)"
ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
SHOWS="${JELLYFIN_SHOWS:-/data/jellyfin/Shows}"
JELLYFIN_URL="${JELLYFIN_URL:-http://localhost:8096}"
JELLYFIN_API_KEY="${JELLYFIN_API_KEY:-}"
dim()  { printf '\033[90m%s\033[0m\n' "$*"; }   # grey hint text
bold() { printf '\033[1m%s\033[0m\n'  "$*"; }

# --- matcher: argv = show_root scan_root src lang [apply archive flatten] ---
PY=$(cat <<'PYEOF'
import sys, os, re, shutil, tempfile, zipfile
VIDEO_EXT=(".mkv",".mp4",".avi",".m4v"); SUB_EXT=(".srt",".ass",".ssa",".vtt",".sub")
CODE=re.compile(r'[Ss](\d{1,2})[ ._-]*[Ee](\d{1,2})')
def codeof(n):
    m=CODE.search(n); return (int(m.group(1)),int(m.group(2))) if m else None
def find(root,exts):
    out=[]
    for d,_,fs in os.walk(root):
        for f in fs:
            if f.lower().endswith(exts): out.append(os.path.join(d,f))
    return out
show_root, scan_root, src, lang = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
flags=set(sys.argv[5:]); apply="apply" in flags; archive="archive" in flags; flatten="flatten" in flags; quiet="quiet" in flags
if flatten and apply:
    for inner in sorted([d for d,_,_ in os.walk(scan_root)
                         if os.path.basename(d)==os.path.basename(os.path.dirname(d))],
                        key=len, reverse=True):
        parent=os.path.dirname(inner)
        for e in os.listdir(inner): shutil.move(os.path.join(inner,e), os.path.join(parent,e))
        os.rmdir(inner); print("FLATTEN  "+inner)
tmp=None
if os.path.isfile(src) and src.lower().endswith(".zip"):
    tmp=tempfile.mkdtemp(prefix="subs-")
    with zipfile.ZipFile(src) as z: z.extractall(tmp)
    src=tmp
subs={}
for f in find(src,SUB_EXT):
    c=codeof(os.path.basename(f))
    if c: subs.setdefault(c,[]).append(f)
seasons={s for s,_ in subs}
m=mi=0
for v in sorted(find(scan_root,VIDEO_EXT)):
    c=codeof(os.path.basename(v))
    if not c or c[0] not in seasons: continue
    ss=subs.get(c)
    if not ss:
        if not quiet: print("NO SUB   S%02dE%02d  %s"%(c[0],c[1],os.path.basename(v)))
        mi+=1; continue
    for s in ss:
        ext=os.path.splitext(s)[1].lower(); dst=os.path.splitext(v)[0]+"."+lang+ext
        if not quiet: print("S%02dE%02d  %s  ->  %s"%(c[0],c[1],os.path.basename(s),os.path.basename(dst)))
        if apply:
            shutil.copy2(s,dst)
            if archive:
                ad=os.path.join(show_root,"Subtitles","Season %02d"%c[0]); os.makedirs(ad,exist_ok=True)
                shutil.copy2(s,os.path.join(ad,os.path.basename(dst)))
        m+=1
print("\n%s  matched=%d  missing=%d"%("APPLIED" if apply else "DRY-RUN",m,mi))
if seasons: print("Applies to: " + ", ".join("Season %02d"%s for s in sorted(seasons)))
if tmp: shutil.rmtree(tmp,ignore_errors=True)
PYEOF
)

bold "Jellyfin subtitle importer"

# 1) pick a show
mapfile -t SHOWLIST < <(find "$SHOWS" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
dim "Shows under $SHOWS"
for i in "${!SHOWLIST[@]}"; do echo "  $((i+1))- ${SHOWLIST[$i]}"; done
read -rp "Show (number or name): " SHOW_IN
if [[ "$SHOW_IN" =~ ^[0-9]+$ ]] && [ "$SHOW_IN" -ge 1 ] && [ "$SHOW_IN" -le "${#SHOWLIST[@]}" ]; then
  SHOW_IN="${SHOWLIST[$((SHOW_IN-1))]}"
fi
SHOW="$SHOW_IN"; [ -d "$SHOW" ] || SHOW="$SHOWS/$SHOW_IN"
[ -d "$SHOW" ] || { echo "Show folder not found: $SHOW"; exit 1; }

# 2) pick a season (0 = all)
mapfile -t SEASONLIST < <(find "$SHOW" -maxdepth 1 -mindepth 1 -type d -iname 'Season *' -printf '%f\n' 2>/dev/null | sort)
echo "Seasons in $(basename "$SHOW"):"
echo "  0- All seasons"
for i in "${!SEASONLIST[@]}"; do echo "  $((i+1))- ${SEASONLIST[$i]}"; done
read -rp "Season (number or name) [0=all]: " SEA_IN
SEA_IN="${SEA_IN:-0}"
if [[ "$SEA_IN" =~ ^[0-9]+$ ]]; then
  if [ "$SEA_IN" -eq 0 ]; then SCAN="$SHOW"
  elif [ "$SEA_IN" -ge 1 ] && [ "$SEA_IN" -le "${#SEASONLIST[@]}" ]; then SCAN="$SHOW/${SEASONLIST[$((SEA_IN-1))]}"
  else echo "Invalid season number."; exit 1; fi
else
  SCAN="$SHOW/$SEA_IN"; [ -d "$SCAN" ] || SCAN="$SEA_IN"
fi
[ -d "$SCAN" ] || { echo "Season folder not found: $SCAN"; exit 1; }

# 3) subtitles + language
read -rp "Subtitles .zip or folder [/tmp/subtitles.zip]: " SRC
SRC="${SRC:-/tmp/subtitles.zip}"
[ -e "$SRC" ] || { echo "Subtitles not found: $SRC"; exit 1; }
read -rp "Language tag [ara]: " LANG
LANG="${LANG:-ara}"

# 4) preview -> confirm -> apply
echo "----- preview -----"
python3 -c "$PY" "$SHOW" "$SCAN" "$SRC" "$LANG"
read -rp "Apply (place + archive + flatten)? [y/N] " A
if [[ "$A" =~ ^[Yy] ]]; then
  python3 -c "$PY" "$SHOW" "$SCAN" "$SRC" "$LANG" apply archive flatten quiet
  if [ -n "$JELLYFIN_API_KEY" ]; then
    KEY="$JELLYFIN_API_KEY"; dim "scanning Jellyfin (API key from .env)"
  else
    dim "API key:  Jellyfin Dashboard -> Advanced -> API Keys -> +   (save in .env to skip this)"
    dim "or leave blank and scan later: Dashboard -> Libraries -> Scan All Libraries"
    read -rsp "Jellyfin API key for auto-scan: " KEY; echo
  fi
  if [ -n "$KEY" ]; then
    curl -s -o /dev/null -w "scan: HTTP %{http_code}\n" -X POST \
      -H "Authorization: MediaBrowser Token=\"$KEY\"" \
      "$JELLYFIN_URL/Library/Refresh"
  fi
else
  echo "Aborted."
fi
