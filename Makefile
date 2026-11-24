# 便捷入口：make prepare / make build / make build DEVICES="..." / make verify
.PHONY: prepare build verify clean help

prepare:
	./scripts/prepare.sh

build:
	./scripts/build.sh $(if $(DEVICES),$(addprefix --device ,$(DEVICES)),--all) $(ARGS)

verify:
	./scripts/verify.sh

clean:
	rm -rf source firmware

help:
	@sed -n '1,12p' README.md
