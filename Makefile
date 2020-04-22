DOCKER_PREFIX ?= ktchen14
STACK := stack --docker

docker:
	$(STACK) --local-bin-path . build --copy-bins .
	docker build -t $(DOCKER_PREFIX)/static-resource .
	docker push $(DOCKER_PREFIX)/static-resource
