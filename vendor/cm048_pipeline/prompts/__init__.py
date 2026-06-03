# Marker so setuptools ships the prompt .md templates as package data.
# The pipeline loads these by filesystem path (src/prompts.py), not by
# import; this file exists only to make `prompts/` an installable package
# so its *.md land in site-packages/prompts/ alongside src/.
