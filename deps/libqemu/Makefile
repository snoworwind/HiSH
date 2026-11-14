include ../utils/Makefrag
include source.env

QEMU_SYSTEM_OUTPUT := libqemu-system-aarch64.so
ifeq ($(QEMU_TCI),1)
QEMU_SYSTEM_OUTPUT := libqemu-system-aarch64-tci.so
endif

all: download/qemu
	cd download/qemu && git fetch --depth=1 $(QEMU_REPOSITORY) $(QEMU_REVISION)
	rm -rf temp build
	mkdir -p temp/qemu build
	cd download/qemu && git archive $(QEMU_REVISION) | tar -x -C $(abspath temp/qemu)
	OHOS_DEPS_PREFIX=$(abspath ../buildroot) TARGET_ARCH=$(OHOS_ARCH) QEMU_TCI=$(QEMU_TCI) \
	BUILD_DIR=$(abspath temp/qemu/build) bash temp/qemu/scripts/ohos/build.sh
	bash temp/qemu/scripts/ohos/verify.sh temp/qemu/build $(OHOS_ARCH)
	cp temp/qemu/pc-bios/efi-virtio.rom ./build
	cp temp/qemu/build/$(QEMU_SYSTEM_OUTPUT) ./build/
	cp temp/qemu/build/libqemu-img.so ./build
	cp temp/qemu/build/subprojects/slirp/libslirp.so.0.4.0 ./build/libslirp.so.0
	cp temp/qemu/pc-bios/keymaps/en-us ./build/
	mkdir -p ../output
	cp -rv ./build/* ../output

download/qemu:
	mkdir -p download
	cd download && git clone -b $(QEMU_BRANCH) --depth=1 $(QEMU_REPOSITORY) qemu
