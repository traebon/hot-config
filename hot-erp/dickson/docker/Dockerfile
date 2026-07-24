FROM frappe/erpnext:v16

USER root
RUN apt-get update && apt-get install -y --no-install-recommends git  && rm -rf /var/lib/apt/lists/*

USER frappe
WORKDIR /home/frappe/frappe-bench

# bench get-app's own installer uses uv with build isolation, which breaks
# posawesome's setup.py (it does "import frappe" at build time, which only
# exists in this bench's own venv, not an isolated build env). Clone directly
# and install into the bench's venv with --no-build-isolation instead.
RUN cd apps \
 && git clone https://github.com/yrestom/POS-Awesome.git --branch develop --depth 1 posawesome \
 && cd /home/frappe/frappe-bench \
 && ./env/bin/pip install setuptools wheel \
 && ./env/bin/pip install --no-build-isolation -e apps/posawesome \
 && printf '\nposawesome\n' >> sites/apps.txt \
 && bench build

# Custom Dickson Supplies branding, injected via Website Settings' custom
# CSS/JS fields. The originals were lost on 2026-07-09 (see custom-assets/
# comments) and are recreated placeholders, not the real branding.
COPY custom-assets/css/dickson-theme.css sites/assets/css/dickson-theme.css
COPY custom-assets/js/inject_dickson_theme.js sites/assets/js/inject_dickson_theme.js

# sites/assets is a named Docker volume, not an image layer -- after any image
# rebuild (new app code, new posawesome version) the volume still holds the
# previous image's assets until something overwrites it, causing hash
# mismatches between what's served and what the backend expects. Keep a
# pristine copy of this image's own build so regen_assets.py can restore it
# into the volume on every container start.
USER root
RUN cp -aL /home/frappe/frappe-bench/sites/assets /opt/assets-image-baked
USER frappe
