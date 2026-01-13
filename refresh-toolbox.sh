#!/usr/bin/env bash
set -euo pipefail

NAME="amd-strix-halo-comfyui"
IMAGE="docker.io/kyuz0/amd-strix-halo-comfyui:latest"
REPO="${IMAGE%:*}"  # docker.io/kyuz0/amd-strix-halo-comfyui

# Get local + remote digests (needs skopeo + jq)
local_digest="$(podman image inspect --format '{{.Digest}}' "$IMAGE" 2>/dev/null || true)"
remote_digest="$(skopeo inspect docker://$IMAGE | jq -r '.Digest')"

if [[ -z "$remote_digest" || "$remote_digest" == "null" ]]; then
  echo "Could not resolve remote digest for $IMAGE"; exit 1
fi

if [[ "$local_digest" == "$remote_digest" ]]; then
  echo "Already up to date."; exit 0
fi

echo "Updating $IMAGE ..."
podman pull "$IMAGE"

echo "Recreating toolbox $NAME ..."
toolbox rm -f "$NAME" 2>/dev/null || true
toolbox create "$NAME" \
  --image "$IMAGE" \
  -- --device /dev/dri --device /dev/kfd \
     --group-add video --group-add render \
     --security-opt seccomp=unconfined

echo "Removing older images from $REPO ..."
# Remove only images from this repo whose digest != the new one
while IFS= read -r line; do
  img_id=$(awk '{print $1}' <<<"$line")
  ref=$(awk '{print $2}' <<<"$line")
  dig=$(awk '{print $3}' <<<"$line")
  [[ -n "$dig" && "$dig" != "$remote_digest" ]] && podman image rm -f "$img_id" || true
done < <(podman images --format '{{.ID}} {{.Repository}}:{{.Tag}} {{.Digest}}' | awk -v r="$REPO" '$2 ~ "^"r":"')

echo "Done."
