#!/bin/bash
# Fine-tunes the curator's picker on the turns this listener approved.
#
# Every time a curated playlist is saved, the app writes the turns that led
# to it — the prompt the model saw and the answer the listener ended up
# with — to Application Support/iTunes Remote/curator/training.jsonl. This
# script trains a LoRA adapter on those with mlx-lm (Apple silicon only),
# fuses it into the base model, imports the result into Ollama as
# "itunes-curator", and points the app at it. Run it again as the file
# grows; each run starts from the base model, not the last adapter.
#
# The base is Qwen 2.5 7B Instruct, not the Qwen 3.5 the stock picker
# uses. Two constraints choose it: mlx-lm must train it inside 24 GB
# (Qwen 3.5's linear-attention layers keep every step's state in the
# backward pass and run out of memory; so does Gemma 4 E4B), and Ollama
# must import the fused result (its converter takes Qwen 2 and Qwen 3.5
# but not plain Qwen 3). Qwen 2.5 7B trains at full length in about 13 GB
# and imports cleanly. A tuned 7B beats a stock 4B at this one job once
# there is data.
#
# It needs a few hundred approved turns to make a difference; it refuses
# to run on fewer than 40 unless told --force. A run takes several hours
# on an M-series Mac (about 25 s a step) and uses the GPU throughout, so
# the curator is slow while it trains.
#
#   ./finetune.sh                train on what is on file
#   ./finetune.sh --force        even with few examples (to try the pipeline)
#   ./finetune.sh --revert       go back to the stock picker
#   ./finetune.sh --check        print what is on file and what is installed
#   ./finetune.sh --fetch-python get uv and Python 3.12 into ~/.local (no admin)
#
# The app runs this same file (Controls ▸ Train Curator on My Edits…) and
# reads its progress from the @@ lines it prints when ITR_PROGRESS is set.
#
# Environment: ITR_ITERS (training steps; default from the data size),
# ITR_BASE_MODEL (Hugging Face id of the 4-bit MLX base), ITR_TUNED_NAME,
# ITR_NO_SWITCH=1 (build the model but leave the app on its current picker),
# ITR_OLLAMA (path to the ollama binary to import with, with OLLAMA_HOST and
# OLLAMA_MODELS set to match), ITR_PROGRESS=1 (machine-readable progress).
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/iTunes Remote"
DATA="$SUPPORT/curator/training.jsonl"
WORK="$SUPPORT/finetune"
BASE="${ITR_BASE_MODEL:-mlx-community/Qwen2.5-7B-Instruct-4bit}"
STOCK="qwen3.5:4b"
NAME="${ITR_TUNED_NAME:-itunes-curator}"
MIN="${ITR_MIN_EXAMPLES:-40}"
DEFAULTS_DOMAIN="local.stevenbleifer.itunesremote"
FORCE=""
CHECK=""
FETCH=""
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        --check) CHECK=1 ;;
        --fetch-python) FETCH=1 ;;
        --revert)
            defaults write "$DEFAULTS_DOMAIN" curatorModel "$STOCK"
            echo "The app will use $STOCK again from its next question."
            exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
stage() { bold "$*"; [ -n "${ITR_PROGRESS:-}" ] && echo "@@stage $*" || true; }

# A long step runs as a child so that a TERM to this script (the app's
# Cancel, or the app quitting) reaches it; without this the trainer
# would run on, holding the GPU, after the script was gone.
CHILD=""
trap 'if [ -n "$CHILD" ]; then kill "$CHILD" 2>/dev/null; fi; exit 130' TERM INT
step() { "$@" & CHILD=$!; wait "$CHILD"; local rc=$?; CHILD=""; return $rc; }

new_enough() { [ -x "$1" ] && "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; }
find_python() {
    local UV="$(command -v uv || true)"; [ -x "$HOME/.local/bin/uv" ] && UV="$HOME/.local/bin/uv"
    if [ -n "$UV" ]; then
        local p="$("$UV" python find 3.12 2>/dev/null || true)"
        [ -n "$p" ] && { echo "$p"; return; }
    fi
    for c in python3.13 python3.12 python3.11 python3.10 /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
        local path="$(command -v "$c" 2>/dev/null || true)"
        if [ -n "$path" ] && new_enough "$path"; then echo "$path"; return; fi
    done
}

# --check: what the app's training window shows. Nothing is changed.
if [ -n "$CHECK" ]; then
    N=0; [ -f "$DATA" ] && N="$(grep -c . "$DATA" || true)"
    echo "examples $N"
    echo "minimum $MIN"
    PYB="$(find_python)"; echo "python ${PYB:-none}"
    echo "tuned $(defaults read "$DEFAULTS_DOMAIN" curatorModel 2>/dev/null || echo "$STOCK")"
    echo "stock $STOCK"
    exit 0
fi

# --fetch-python: uv from astral.sh into ~/.local/bin, then a standalone
# CPython 3.12 under ~/.local/share/uv. About 100 MB; no administrator.
if [ -n "$FETCH" ]; then
    if [ ! -x "$HOME/.local/bin/uv" ]; then
        stage "Fetching uv…"
        TMP="$(mktemp -d)"
        step curl -LsSf https://astral.sh/uv/install.sh -o "$TMP/uv-install.sh"
        step sh "$TMP/uv-install.sh" --quiet
        rm -rf "$TMP"
    fi
    stage "Fetching Python 3.12…"
    step "$HOME/.local/bin/uv" python install 3.12
    echo "python $("$HOME/.local/bin/uv" python find 3.12)"
    exit 0
fi

# 0. Where Ollama is: as the app says, else the app on this Mac, else the
#    copy inside iTunes Remote.
OLLAMA="${ITR_OLLAMA:-}"
if [ -z "$OLLAMA" ] && curl -s -m 2 -o /dev/null http://127.0.0.1:11434/api/version; then
    OLLAMA="$(command -v ollama || true)"
    [ -n "$OLLAMA" ] || OLLAMA="/Applications/Ollama.app/Contents/Resources/ollama"
fi
if [ -z "$OLLAMA" ] || [ ! -x "$OLLAMA" ]; then
    EMB="/Applications/iTunes Remote.app/Contents/Helpers/ollama/ollama"
    [ -x "$EMB" ] || { echo "No Ollama found: neither the Ollama app nor iTunes Remote in /Applications." >&2; exit 1; }
    OLLAMA="$EMB"
    export OLLAMA_HOST="127.0.0.1:11435" OLLAMA_MODELS="$SUPPORT/ollama/models"
    curl -s -m 2 -o /dev/null "http://$OLLAMA_HOST/api/version" || { echo "Open iTunes Remote first: its built-in Ollama is not running." >&2; exit 1; }
fi

# 1. The data.
[ -f "$DATA" ] || { echo "No approved turns yet: $DATA does not exist. Save a few curated playlists first." >&2; exit 1; }
N="$(grep -c . "$DATA")"
echo "Approved turns on file: $N"
if [ "$N" -lt "$MIN" ] && [ -z "$FORCE" ]; then
    echo "That is under $MIN; a fine-tune on so few will not help. Save more playlists, or pass --force to try the pipeline anyway." >&2
    exit 1
fi

# 2. Tools: Python 3.10 or newer (the mlx-lm that knows Qwen 3.5 needs it;
#    macOS ships 3.9) in a private venv with mlx-lm. A Python from uv,
#    python.org or Homebrew all do; without one, uv fetches a standalone
#    3.12 into your home folder with no administrator password.
mkdir -p "$WORK"
if ! new_enough "$WORK/venv/bin/python"; then
    rm -rf "$WORK/venv"
    PYBASE="$(find_python)"
    if [ -z "$PYBASE" ]; then
        echo "Python 3.10 or newer is needed and none was found. Either install Python 3.12 from" >&2
        echo "https://www.python.org/downloads/macos/ or run these two lines and try again:" >&2
        echo "    curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
        echo "    ~/.local/bin/uv python install 3.12" >&2
        exit 1
    fi
    stage "Setting up Python for training (one time, $PYBASE)…"
    "$PYBASE" -m venv "$WORK/venv"
fi
stage "Checking the training library…"
step "$WORK/venv/bin/pip" install -q --upgrade pip mlx-lm >/dev/null
PY="$WORK/venv/bin/python"
echo "Python $("$PY" -c 'import platform; print(platform.python_version())'), mlx-lm $("$PY" -c 'import mlx_lm; print(mlx_lm.__version__)')"

# 3. Split: nine in ten to train on, the rest to check against.
rm -rf "$WORK/data"; mkdir -p "$WORK/data"
"$PY" - "$DATA" "$WORK/data" <<'PYEOF'
import json, random, sys
src, out = sys.argv[1], sys.argv[2]
rows = [l for l in open(src, encoding="utf-8") if l.strip()]
# The same turn approved twice is one example.
seen, uniq = set(), []
for r in rows:
    if r not in seen:
        seen.add(r); uniq.append(r)
random.Random(7).shuffle(uniq)
nv = max(1, len(uniq) // 10) if len(uniq) > 1 else 0
valid, train = uniq[:nv], uniq[nv:]
if not train: train, valid = uniq, uniq
if not valid: valid = train[:1]
open(f"{out}/train.jsonl", "w").writelines(train)
open(f"{out}/valid.jsonl", "w").writelines(valid)
open(f"{out}/test.jsonl", "w").writelines(valid)
print(f"train {len(train)}, valid {len(valid)}")
PYEOF

# 4. Train. Only the answer is learned (--mask-prompt): the prompt is a
#    long candidate list the model is shown, not something it should write.
ITERS="${ITR_ITERS:-}"
if [ -z "$ITERS" ]; then
    ITERS=$(( N * 6 )); [ "$ITERS" -lt 100 ] && ITERS=100; [ "$ITERS" -gt 800 ] && ITERS=800
fi
stage "Fetching the base model, $BASE (about 4.5 GB the first time)…"
# The whole snapshot, not just the weights: fuse opens it offline, and the
# hub library refuses a snapshot with files missing.
step "$PY" -c 'import sys; from huggingface_hub import snapshot_download; snapshot_download(sys.argv[1])' "$BASE" 2>&1 | grep -v "warn" | tail -1 || true
stage "Training $ITERS steps…"
[ -n "${ITR_PROGRESS:-}" ] && echo "@@iters $ITERS"
rm -rf "$WORK/adapters"
step "$PY" -m mlx_lm lora --model "$BASE" --train --data "$WORK/data" \
    --iters "$ITERS" --batch-size 1 --num-layers 8 --learning-rate 1e-5 \
    --max-seq-length 12288 --grad-checkpoint --mask-prompt \
    --steps-per-eval 50 --steps-per-report 10 --save-every 100 \
    --adapter-path "$WORK/adapters"

# 5. Fuse the adapter into full weights Ollama can read.
stage "Fusing the adapter into the model…"
rm -rf "$WORK/fused"
step "$PY" -m mlx_lm fuse --model "$BASE" --adapter-path "$WORK/adapters" --save-path "$WORK/fused" --dequantize

# 6. Into Ollama, quantised the way the stock picker is. The chat template
#    comes from the fused model's own tokenizer files; the app sets
#    temperature and context per question.
stage "Importing into Ollama as $NAME (a few minutes)…"
printf 'FROM %s\nPARAMETER num_ctx 16384\n' "$WORK/fused" > "$WORK/Modelfile"
step "$OLLAMA" create "$NAME" --quantize q4_K_M -f "$WORK/Modelfile"
rm -rf "$WORK/fused"

# 7. Point the app at it.
if [ -n "${ITR_NO_SWITCH:-}" ]; then
    echo; bold "Done. $NAME is in Ollama; the app was left on its current picker."
    exit 0
fi
defaults write "$DEFAULTS_DOMAIN" curatorModel "$NAME"
echo
bold "Done. The curator uses $NAME from its next question (File ▸ Set Up iTunes Remote… shows it as “Trained on your edits”)."
echo "To go back: ./finetune.sh --revert"
