# Source Audit tools

`source_audit.py` extracts the configurations that the installed OKVideoMac app
actually persists, builds a redacted source inventory, downloads referenced code
assets into `SourceAuditCache`, and performs static archive analysis.

The cache is intentionally Git-ignored because it can contain private configuration
URLs or raw third-party assets. Public reports contain only redacted URLs, lengths,
and hashes.

```sh
python3 Tools/SourceAudit/source_audit.py extract
python3 Tools/SourceAudit/source_audit.py fetch
python3 Tools/SourceAudit/source_audit.py analyze
python3 Tools/SourceAudit/source_audit.py all
```

Unknown code is never executed by this script. Dynamic tests are separate and must
match an entry in `allowlist.json` before a runner is invoked.
