# Include this from your device or product makefile:
#
#     $(call inherit-product, vendor/myorg/myappstore/rom/myappstore.mk)
#
# or, if the tree lives elsewhere, just add MyAppStore to PRODUCT_PACKAGES
# yourself. Soong picks up rom/Android.bp automatically once the directory is
# inside the build tree.

PRODUCT_PACKAGES += \
    MyAppStore
