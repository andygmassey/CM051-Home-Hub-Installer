"""Package marker so setuptools ships prompts/*.md beside src/.

Vendor-only: no CM048 commit carries this file. It must not be empty --
a zero-byte vendor-only file produces no ``diff -u /dev/null`` hunk, so
vendor/divergences cannot describe it and sync_vendor.sh would delete it
on the next swap. See vendor/VENDOR_ONLY.tsv for the measurement.
"""
