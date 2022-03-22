all: ipxe ubuntu

ubuntu:
	docker build --pull --no-cache -t dbrrg-ubuntu -f Dockerfile.ubuntu .
	docker run --rm -v $$PWD/scripts:/scripts -v $$PWD/image-export:/image-export dbrrg-ubuntu /scripts/image-export.sh

ipxe:
	docker build --pull -t dbrrg-ipxe -f Dockerfile.ipxe .
	docker run --rm -v $$PWD/scripts:/scripts -v $$PWD/image-export:/image-export dbrrg-ipxe /scripts/make-ipxe.sh

server:
	docker run --rm -v $$PWD:/app -w /app golang:1.17 go build -v