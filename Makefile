.PHONY: build
build:
	docker build \
		--no-cache \
		-t lgb-glibc-demo:local \
		- < ./Dockerfile
