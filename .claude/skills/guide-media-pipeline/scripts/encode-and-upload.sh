#!/bin/zsh
# Encode the recorded clips and upload all media to R2.
# Contract: worker serves /media/<basename> from wink-releases: wink/guide/.
# Videos crop to 1480x1000 (guide <video> width/height attrs must match).
set -eu
WORK="${WINK_MEDIA_WORK:-$HOME/.cache/wink-guide-media}"
MEDIA="$WORK/media"
mkdir -p "$MEDIA"

for src in "$WORK"/rec/clip-*.mov; do
  name="guide-${${src:t:r}#clip-}"
  ffmpeg -loglevel error -ss 1.2 -i "$src" -vf "crop=1480:1000:280:80" \
    -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p -movflags +faststart -an \
    -y "$MEDIA/$name.mp4"
  echo "encoded $name.mp4 ($(du -h "$MEDIA/$name.mp4" | cut -f1))"
done

echo "REVIEW GATE: inspect every clip and screenshot before uploading."
echo "  e.g. ffmpeg -ss 3 -i $MEDIA/guide-cycle.mp4 -frames:v 1 frame.jpg"
read -r "?Upload $MEDIA/*.mp4 and $WORK/shots/*.png to wink-releases/wink/guide/ ? [y/N] " yn
[ "$yn" = "y" ] || { echo "aborted before upload"; exit 1; }

for f in "$MEDIA"/*.mp4; do
  npx --yes wrangler@latest r2 object put "wink-releases/wink/guide/${f:t}" \
    --file "$f" --content-type video/mp4 --remote
done
for f in "$WORK"/shots/*.png; do
  npx --yes wrangler@latest r2 object put "wink-releases/wink/guide/${f:t}" \
    --file "$f" --content-type image/png --remote
done
echo "UPLOAD_DONE — verify: curl -sI -H 'Range: bytes=0-1' https://wink.aixie.de/media/guide-cycle.mp4"
