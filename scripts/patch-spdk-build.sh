#!/bin/sh
set -eu

root="$1"
dpdk_options="$root/dpdk/meson_options.txt"
python_makefile="$root/python/Makefile"
common_makefile="$root/mk/spdk.common.mk"

if [ -f "$python_makefile" ]; then
  if grep -q "setup_cmd = pip install --prefix=\$(CONFIG_PREFIX)" "$python_makefile"; then
    sed -i \
      "s#setup_cmd = pip install --prefix=\$(CONFIG_PREFIX)#setup_cmd = python3 -m pip install --prefix=\$(CONFIG_PREFIX)#" \
      "$python_makefile"
  fi
  if ! grep -q "python3 -m pip --version >/dev/null 2>&1" "$python_makefile"; then
    sed -i \
      "s#\$(Q)\$(setup_cmd) \$(SPDK_ROOT_DIR)/python#\$(Q)python3 -m pip --version >/dev/null 2>\&1 \&\& \$(setup_cmd) \$(SPDK_ROOT_DIR)/python || true#" \
      "$python_makefile"
  fi
fi

if [ -f "$common_makefile" ]; then
  if ! grep -q "command -v patchelf >/dev/null 2>&1 && patchelf --remove-rpath" "$common_makefile"; then
    sed -i \
      "s#patchelf --remove-rpath#command -v patchelf >/dev/null 2>\&1 \&\& patchelf --remove-rpath#g" \
      "$common_makefile"
  fi
fi
