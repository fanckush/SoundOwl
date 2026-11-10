#!/bin/sh
# Builds call-like clips for the live feasibility test (soundowl-dev lookahead).
#
#   scripts/lookahead-corpus.sh [out-dir]        # default build/lookahead-corpus
#
# Takes the site's before-clips and the engine fixtures and runs them through the codecs calls
# actually use, with macOS's own afconvert: Opus at narrowband (8 kHz), wideband (16 kHz) and
# super-wideband (24 kHz) rates, and G.711 μ-law as on a phone line. Real call recordings beat
# all of these: drop a few (Zoom, Meet, Teams; any format) into the same folder.
set -eu
cd "$(dirname "$0")/.."

OUT=${1:-build/lookahead-corpus}
mkdir -p "$OUT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# encode <name> <source> <format@rate> [bitrate]
encode() {
    name=$1 source=$2 format=$3
    if [ $# -ge 4 ]; then
        afconvert -f caff -d "$format" -b "$4" "$source" "$TMP/$name.caf"
    else
        afconvert -f caff -d "$format" "$source" "$TMP/$name.caf"
    fi
    afconvert -f WAVE -d LEF32 "$TMP/$name.caf" "$OUT/$name.wav"
    echo "  $OUT/$name.wav"
}

echo "Call-like clips:"
for clip in podcast noisy; do
    source=site/samples/$clip-before.m4a
    encode "$clip-opus-nb-12k" "$source" opus@8000 12000
    encode "$clip-opus-wb-16k" "$source" opus@16000 16000
    encode "$clip-opus-swb-24k" "$source" opus@24000 24000
    encode "$clip-g711" "$source" ulaw@8000
done

echo "As recorded:"
for source in site/samples/phone-before.m4a site/samples/podcast-before.m4a \
    Tests/Fixtures/lavasr-v2/speech-16k.in.wav Tests/Fixtures/lavasr-v2/phone-8k.in.wav; do
    name=$(basename "$source" | sed 's/\.[^.]*$//; s/\.in$//')
    afconvert -f WAVE -d LEF32 "$source" "$OUT/$name.wav"
    echo "  $OUT/$name.wav"
done

echo "Next: add real call recordings to $OUT, then"
echo "  swift run -c release soundowl-dev lookahead $OUT/* --out build/lookahead --load 4"
