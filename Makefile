all:
	mkdir -p rrx
	docker build --pull -t dbrrg .
	docker run --rm -v $$PWD/image-export:/image-export --name dbrrg-export dbrrg /bin/image-export.sh
