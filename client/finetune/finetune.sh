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
# It needs a few hundred approved turns to make a difference; it refuses
# to run on fewer than 40 unless told --force. A run takes an hour or two
# on an M-series Mac and uses the GPU throughout, so the curator is slow
# while it trains.
#
#   ./finetune.sh              train on what is on file
#   ./finetune.sh --force      even with few examples (to try the pipeline)
#   ./finetune.sh --revert     go back to the stock picker
#
# Environment: ITR_ITERS (training steps; default from the data size),
# ITR_BASE_MODEL (Hugging Face id of the 4-bit MLX base), ITR_TUNED_NAME.
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/iTunes Remote"
DATA="$SUPPORT/curator/training.jsonl"
WORK="$SUPPORT/finetune"
BASE="${ITR_BASE_MODEL:-mlx-community/Qwen3.5-4B-MLX-4bit}"
STOCK="qwen3.5:4b"
NAME="${ITR_TUNED_NAME:-itunes-curator}"
MIN="${ITR_MIN_EXAMPLES:-40}"
DEFAULTS_DOMAIN="local.stevenbleifer.itunesremote"
FORCE=""
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        --revert)
            defaults write "$DEFAULTS_DOMAIN" curatorModel "$STOCK"
            echo "The app will use $STOCK again from its next question."
            exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

# 0. Where Ollama is: the app on this Mac, or the copy inside iTunes Remote.
OLLAMA=""
if curl -s -m 2 -o /dev/null http://127.0.0.1:11434/api/version; then
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
new_enough() { [ -x "$1" ] && "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; }
if ! new_enough "$WORK/venv/bin/python"; then
    rm -rf "$WORK/venv"
    PYBASE=""
    UV="$(command -v uv || true)"; [ -x "$HOME/.local/bin/uv" ] && UV="$HOME/.local/bin/uv"
    if [ -n "$UV" ]; then
        PYBASE="$("$UV" python find 3.12 2>/dev/null || true)"
        if [ -z "$PYBASE" ]; then "$UV" python install 3.12 >/dev/null 2>&1; PYBASE="$("$UV" python find 3.12 2>/dev/null || true)"; fi
    fi
    if [ -z "$PYBASE" ]; then
        for c in python3.13 python3.12 python3.11 python3.10 /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
            path="$(command -v "$c" 2>/dev/null || true)"
            if [ -n "$path" ] && new_enough "$path"; then PYBASE="$path"; break; fi
        done
    fi
    if [ -z "$PYBASE" ]; then
        echo "Python 3.10 or newer is needed and none was found. Either install Python 3.12 from" >&2
        echo "https://www.python.org/downloads/macos/ or run these two lines and try again:" >&2
        echo "    curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
        echo "    ~/.local/bin/uv python install 3.12" >&2
        exit 1
    fi
    bold "Setting up Python for training (one time, $PYBASE)…"
    "$PYBASE" -m venv "$WORK/venv"
fi
"$WORK/venv/bin/pip" install -q --upgrade pip mlx-lm >/dev/null
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
    ITERS=$(( N * 6 )); [ "$ITERS" -lt 100 ] && ITERS=100; [ "$ITERS" -gt 1500 ] && ITERS=1500
fi
bold "Training $ITERS steps on $BASE (the first run downloads the base, about 3 GB)…"
rm -rf "$WORK/adapters"
"$PY" -m mlx_lm lora --model "$BASE" --train --data "$WORK/data" \
    --iters "$ITERS" --batch-size 1 --num-layers 8 --learning-rate 1e-5 \
    --max-seq-length 12288 --grad-checkpoint --mask-prompt \
    --steps-per-eval 50 --steps-per-report 10 --save-every 100 \
    --adapter-path "$WORK/adapters"

# 5. Fuse the adapter into full weights Ollama can read.
bold "Fusing…"
rm -rf "$WORK/fused"
"$PY" -m mlx_lm fuse --model "$BASE" --adapter-path "$WORK/adapters" --save-path "$WORK/fused" --dequantize

# 6. Into Ollama, quantised the way the stock model is, with its parameters.
bold "Importing into Ollama as $NAME…"
{
    echo "FROM $WORK/fused"
    "$OLLAMA" show --modelfile "$STOCK" 2>/dev/null | grep -E '^(PARAMETER|TEMPLATE)' || true
} > "$WORK/Modelfile"
"$OLLAMA" create "$NAME" --quantize q4_K_M -f "$WORK/Modelfile"

# 7. Point the app at it.
defaults write "$DEFAULTS_DOMAIN" curatorModel "$NAME"
echo
bold "Done. The curator uses $NAME from its next question (File ▸ Set Up iTunes Remote… shows it as “Trained on your edits”)."
echo "To go back: ./finetune.sh --revert"
