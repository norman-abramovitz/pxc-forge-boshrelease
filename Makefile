.DEFAULT_GOAL := targets
.PHONY: targets dev test clean

targets:
	@echo "Available targets:"
	@echo "  dev   - Create development release tarball"
	@echo "  test  - Render the plan templates and check them (needs the bosh-template and rspec gems, and graft)"
	@echo "  clean - Remove the dev release tarball"

dev:
	bosh create-release --force --tarball="$$PWD/pxc-forge-dev.tar.gz"

test:
	ruby -e 'require "rspec/core"; exit RSpec::Core::Runner.run(["spec"])'

clean:
	rm -f pxc-forge-dev.tar.gz
