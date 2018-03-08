DOCKER_PREFIX ?= vaneci
STACK := stack --docker --verbosity error

docker:
	$(STACK) --local-bin-path . build --copy-bins .
	docker build -t $(DOCKER_PREFIX)/static-resource .
	docker push $(DOCKER_PREFIX)/static-resource
