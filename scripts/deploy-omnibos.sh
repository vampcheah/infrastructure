#!/usr/bin/env bash
# Build and deploy one clean OmniBOS main revision to the existing production host.
set -euo pipefail
umask 077

INFRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${OMNIBOS_SOURCE:?set OMNIBOS_SOURCE to the OmniBOS checkout}"

die() {
	echo "deploy-omnibos: $*" >&2
	exit 1
}

[ -d "$SOURCE/.git" ] && [ -f "$SOURCE/server/Dockerfile" ] ||
	die "OMNIBOS_SOURCE is not an OmniBOS checkout"
SOURCE="$(cd "$SOURCE" && pwd -P)"

if [ -r "$SOURCE/.env" ]; then
	set -a
	# shellcheck source=/dev/null
	. "$SOURCE/.env"
	set +a
fi

DEPLOY_HOST="${DEPLOY_HOST:-}"
DEPLOY_DIR="${DEPLOY_DIR:-.omnibos-release}"
SSH_PORT="${SSH_PORT:-22}"
PUBLIC_HEALTH_URL="${PUBLIC_HEALTH_URL:-https://omnibos-api.move2.work/health}"
RELEASE_DIR=""

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
	[ -z "$RELEASE_DIR" ] || [ ! -d "$RELEASE_DIR" ] ||
		find "$RELEASE_DIR" -depth -delete
}
trap cleanup EXIT

[[ "$DEPLOY_DIR" != "$HOME/"* ]] || DEPLOY_DIR="${DEPLOY_DIR#"$HOME"/}"
[[ "$DEPLOY_DIR" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "/$DEPLOY_DIR/" != *"/../"* ]] ||
	die "DEPLOY_DIR must be a safe relative or absolute path"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
	die "SSH_PORT must be between 1 and 65535"
fi
[[ "$DEPLOY_HOST" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*@)?[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
	die "DEPLOY_HOST must be an SSH alias, host, or user@host"

for command_name in curl docker git gzip rsync sha256sum ssh; do
	command -v "$command_name" >/dev/null || die "missing command: $command_name"
done

[ "$(git -C "$SOURCE" branch --show-current)" = main ] ||
	die "OmniBOS must be deployed from main"
[ -z "$(git -C "$SOURCE" status --porcelain)" ] ||
	die "OmniBOS worktree must be clean"
REVISION="$(git -C "$SOURCE" rev-parse HEAD)"
REMOTE_REVISION="$(git -C "$SOURCE" ls-remote origin refs/heads/main | cut -f1)"
[ "$REVISION" = "$REMOTE_REVISION" ] ||
	die "local OmniBOS main does not match origin/main"
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || die "invalid Git revision"

IMAGE="omnibos-server:$REVISION"
echo "▸ Building exact OmniBOS revision $REVISION"
docker build --pull \
	--build-arg "OCI_REVISION=$REVISION" \
	-f "$SOURCE/server/Dockerfile" \
	-t "$IMAGE" \
	"$SOURCE/server"

IMAGE_ID="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
OCI_REVISION="$(docker image inspect "$IMAGE" \
	--format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
[[ "$IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid image ID"
[ "$OCI_REVISION" = "$REVISION" ] || die "image revision label mismatch"

RELEASE_DIR="$(mktemp -d)"
IMAGE_BUNDLE="omnibos-server-$REVISION.tar.gz"
docker save "$IMAGE" | gzip -n -c >"$RELEASE_DIR/$IMAGE_BUNDLE"
install -m 0644 "$INFRA_ROOT/config/omnibos/install-server-migrate.sed" \
	"$RELEASE_DIR/install-server-migrate.sed"
(
	cd "$RELEASE_DIR"
	sha256sum "$IMAGE_BUNDLE" install-server-migrate.sed >SHA256SUMS
	sha256sum --check --status SHA256SUMS
)
BUNDLE_SHA="$(sha256sum "$RELEASE_DIR/$IMAGE_BUNDLE" | cut -d' ' -f1)"

echo "▸ Uploading the verified release bundle"
ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 "$DEPLOY_HOST" true
REMOTE_BASE="$(
	ssh -p "$SSH_PORT" "$DEPLOY_HOST" \
		"umask 077; mkdir -p '$DEPLOY_DIR'; cd '$DEPLOY_DIR'; pwd -P"
)"
REMOTE_BASE="${REMOTE_BASE//$'\r'/}"
[[ "$REMOTE_BASE" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid remote release directory"
REMOTE_DIR="$REMOTE_BASE/$REVISION"
ssh -p "$SSH_PORT" "$DEPLOY_HOST" "umask 077; mkdir -p '$REMOTE_DIR'"
rsync -az -e "ssh -p $SSH_PORT" "$RELEASE_DIR/" "$DEPLOY_HOST:$REMOTE_DIR/"

ssh -T -p "$SSH_PORT" "$DEPLOY_HOST" bash -s -- \
	"$REMOTE_DIR" "$IMAGE_BUNDLE" "$IMAGE" "$REVISION" "$BUNDLE_SHA" <<'REMOTE'
set -euo pipefail

release_dir="$1"
image_bundle="$2"
image="$3"
revision="$4"
bundle_sha="$5"
old_installer_sha="214d00d63817dd0210bf8ceea87242514f3fa0e0a1105ab201bb32c72b351a9a"
fixed_installer_sha="b97a1159911adcbb0d0ac5d264b5af41df682d192d0ff3a3cbd1e01969aeee08"

cd "$release_dir"
sha256sum --check --status SHA256SUMS
gzip -dc "$image_bundle" | sudo docker load >/dev/null
loaded_id="$(sudo docker image inspect "$image" --format '{{.Id}}')"
loaded_revision="$(sudo docker image inspect "$image" \
	--format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
[[ "$loaded_id" =~ ^sha256:[0-9a-f]{64}$ ]]
[ "$loaded_revision" = "$revision" ]

check_stable() {
	local expected="$1" path="$2" actual
	actual="$(sudo sha256sum "$path" | cut -d' ' -f1)"
	[ "$actual" = "$expected" ] || {
		echo "deploy-omnibos: unexpected production contract file: $path" >&2
		exit 1
	}
}

check_stable d053fc30346f604e53c1d83840b569416068c85e2fab99457e21640b9804d2c7 \
	/opt/omnibos/compose.yaml
check_stable 6226f89b4fb50a4d60263925a647047575595c8975f70ff7080a30fca3d916a0 \
	/opt/omnibos/.env.example
check_stable ca1f1a00179c4f88722dcf3bea98e6eb98ecb7b3e7acb30d637a573d0aacb0af \
	/opt/omnibos/Makefile
check_stable 6508882bec39e823939bb3b514678caf2d5dc749d07505df188f1d682bd81e1a \
	/opt/omnibos/bin/backup.sh
check_stable c1e51ff671ccfb9b95c6b4cf2d2cc5df7c74ec09bd6b2eb0a0ddca7740de413e \
	/opt/omnibos/bin/restore.sh
check_stable 9724de48df291a90481b03a6fa0286f8449c14af2deb05ae501c65f22eeb40e4 \
	/opt/omnibos/bin/patch-server-to-docker.sh

installer_sha="$(sudo sha256sum /opt/omnibos/bin/install-server.sh | cut -d' ' -f1)"
case "$installer_sha" in
	"$old_installer_sha"|"$fixed_installer_sha") ;;
	*)
		echo "deploy-omnibos: unexpected production installer" >&2
		exit 1
		;;
esac

sudo install -m 0644 /opt/omnibos/compose.yaml "$release_dir/compose.yaml"
sudo install -m 0640 /opt/omnibos/.env.example "$release_dir/.env.example"
sudo install -m 0644 /opt/omnibos/Makefile "$release_dir/Makefile"
sudo install -m 0750 /opt/omnibos/bin/backup.sh "$release_dir/backup.sh"
sudo install -m 0750 /opt/omnibos/bin/restore.sh "$release_dir/restore.sh"
sudo install -m 0750 /opt/omnibos/bin/patch-server-to-docker.sh \
	"$release_dir/patch-server-to-docker.sh"
sudo install -m 0750 /opt/omnibos/bin/install-server.sh "$release_dir/install-server.sh"

if [ "$installer_sha" = "$old_installer_sha" ]; then
	sudo sed -i -f "$release_dir/install-server-migrate.sed" \
		"$release_dir/install-server.sh"
fi
check_stable "$fixed_installer_sha" "$release_dir/install-server.sh"

sudo env \
	OMNIBOS_IMAGE="$image" \
	OMNIBOS_IMAGE_ID="$loaded_id" \
	OMNIBOS_REVISION="$revision" \
	OMNIBOS_BUNDLE_SHA="$bundle_sha" \
	"$release_dir/install-server.sh"

container_id="$(
	sudo docker compose --env-file /opt/omnibos/deploy.env \
		-f /opt/omnibos/compose.yaml ps -q server
)"
[ -n "$container_id" ]
[ "$(sudo docker inspect "$container_id" --format '{{.Image}}')" = "$loaded_id" ]
[ "$(sudo docker inspect "$container_id" \
	--format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$revision" ]
[ "$(sudo docker inspect "$container_id" \
	--format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')" = healthy ]
curl -fsS http://127.0.0.1:8080/health >/dev/null
REMOTE

echo "▸ Verifying the public API"
for _ in $(seq 1 30); do
	if curl -fsS --max-time 10 "$PUBLIC_HEALTH_URL" >/dev/null; then
		echo "✓ OmniBOS backend is healthy at revision $REVISION"
		exit 0
	fi
	sleep 1
done
die "public API did not become healthy"
