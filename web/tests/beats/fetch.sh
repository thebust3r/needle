#!/bin/sh
# Downloads the real test songs (librosa's public test recordings, Creative Commons) and makes reference beats.
# Usage: sh fetch.sh /some/folder   then:  node score.js /some/folder   and   node neg.js /some/folder
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=${1:?folder}; mkdir -p "$DIR/neg"; cd "$DIR"
[ -d ld ] || { git clone -q --depth 1 --filter=blob:none --sparse https://github.com/librosa/data.git ld; (cd ld && git sparse-checkout set audio); }
for f in "Kevin_MacLeod_-_Vibe_Ace" "admiralbob77_-_Choice_-_Drum-bass" "Karissa_Hobbs_-_Let's_Go_Fishin'" "442789__lena-orsa__happy-music-pistachio-ice-cream-ragtime"; do
  ffmpeg -loglevel error -y -i "ld/audio/$f.hq.ogg" -ac 2 -ar 44100 -t 60 -f f32le "$(echo "$f" | cut -c1-12 | tr -dc 'A-Za-z0-9_').f32"
done
for f in 198-209-0000 3436-172162-0000 5703-47212-0000 glacier-bay-humpback sorohanro_-_solo-trumpet-06 456440__inspectorj__bird-whistling-robin-single-13; do
  ffmpeg -loglevel error -y -i "ld/audio/$f.hq.ogg" -ac 1 -ar 44100 -t 40 -f f32le "neg/$(echo $f | cut -c1-14).f32"
done
python3 "$HERE/ref.py" . 
python3 -c "import numpy as np, glob, json; json.dump({f: np.load(f).tolist() for f in glob.glob('*.beats.npy')}, open('beats.json', 'w'))"
