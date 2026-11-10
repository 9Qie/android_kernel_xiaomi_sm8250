ifeq ($(CONFIG_MACH_XIAOMI),y)
ifeq ($(CONFIG_MACH_XIAOMI_SM8250),y)
ifeq ($(CONFIG_BUILD_ARM64_DT_OVERLAY),y)

ifeq ($(CONFIG_MACH_XIAOMI_CAS),y)
dtbo-$(CONFIG_MACH_XIAOMI_CAS) += \
                cas-sm8250-overlay.dtbo
cas-sm8250-overlay.dtbo-base := kona.dtb kona-v2.dtb kona-v2.1.dtb
endif

endif
endif
endif

always		:= $(dtb-y)
subdir-y	:= $(dts-dirs)
clean-files    := *.dtb *.dtbo
