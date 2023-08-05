# nhddns

No hassle ddns. Single binary, cross platform. Uses google domains by default.

Configuration done through env vars.

```.env
# required
NHDDNS_USERNAME=
NHDDNS_PASSWORD=
NHDDNS_HOSTNAME=

# optional
NHDDNS_EMAIL=
NHDDNS_TLS=1
NHDDNS_CACHE_DIR=/var/cache/nhddns
NHDDNS_REGISTRY=domains.google.com # untested
```

Not feature complete, for personal use. Feel free to contribute to improve it though
