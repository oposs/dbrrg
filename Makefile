all: ipxe ubuntu

ubuntu:
	podman build --pull --progress=plain  -t dbrrg-ubuntu -f Dockerfile.ubuntu .
	podman run --rm -v $$PWD/scripts:/scripts -v $$PWD/image-export:/image-export dbrrg-ubuntu /scripts/image-export.sh

ipxe:
	podman build --pull --progress=plain  -t dbrrg-ipxe -f Dockerfile.ipxe .
	podman run --rm -v $$PWD/scripts:/scripts -v $$PWD/image-export:/image-export dbrrg-ipxe /scripts/make-ipxe.sh

image: ubuntu ipxe
	podman build --pull -t dbrrg-image -f Dockerfile.image .
	podman run --rm \
		-v $$PWD/scripts:/scripts \
		-v $$PWD/image-export:/image-export \
		-v $$PWD/syslinux.cfg:/syslinux.cfg \
		dbrrg-image /scripts/make-image.sh

server:
	podman run --rm -v $$PWD:/app -w /app golang:1.17 go build -v