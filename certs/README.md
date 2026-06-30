# TLS certificates (optional — only for ingress TLS)

By default this repo exposes AWX over a **NodePort** (`AWX_SERVICE_TYPE=nodeport`,
plain HTTP), so **no certificate is required**.

If you set `AWX_SERVICE_TYPE=ingress` **and** `AWX_INGRESS_TLS=true` in
`config.env`, place two PEM files here before running `install.sh`:

```
certs/
├── cert.pem   # server certificate (full chain: leaf + any intermediates)
└── key.pem    # matching private key (unencrypted)
```

Requirements:

- The certificate's **CN or a SAN** must match `AWX_HOSTNAME` in `config.env`.
- `cert.pem` should include the **full chain** (leaf first, then intermediates).
- `key.pem` must be the **unencrypted** private key (no passphrase prompt).

The install loads these into a Kubernetes TLS secret (`<AWX_NAME>-tls`) and
references it from the AWX ingress. These files are **gitignored**.

## Need a cert for testing?

```bash
# Replace awx.example.com with your AWX_HOSTNAME.
openssl req -x509 -newkey rsa:4096 -nodes -days 825 \
  -keyout certs/key.pem -out certs/cert.pem \
  -subj "/CN=awx.example.com" \
  -addext "subjectAltName=DNS:awx.example.com"
```
