.PHONY: build install test verify package check
build:
	./Scripts/build.sh
install:
	./Scripts/install.sh
test:
	swift test -j 2
verify:
	./Scripts/verify-app.sh
package: build
	./Scripts/package.sh
check: test build verify
	for script in Scripts/*.sh; do bash -n "$$script"; done
