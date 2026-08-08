# fable-repo GPG signing key

The fable-repo flat apt repository is signed with a dedicated, self-signed
ed25519 key. The **public** key is committed here and shipped with every
snapshot; the **private** key exists only in the GitHub Actions secret
`FABLE_REPO_GPG_PRIVATE_KEY` (base64 of the ASCII-armored secret key export).
It is never stored in the repository, workflow logs, or release assets.

## Key facts (verified 2026-08-09)

- Key type: ed25519 (sign only), no passphrase (the secret itself is the
  protection; a passphrase can be added later via secret
  `FABLE_REPO_GPG_PASSPHRASE`)
- Fingerprint: `97291249E5BE2D529939F7F7A960D6CE7BA2DBED`
- Public key assets in every release snapshot:
  - `fable-repo-pub.asc` — ASCII-armored (for distribution/docs)
  - `fable-repo-pub.gpg` — binary keybox form (recommended for
    `trusted.gpg.d/`, because the Termux gpgv build fails to read armored
    keyring files directly; `apt-get update` with `signed-by=` accepts both)

## Setting the secret

```bash
gpg --armor --export-secret-keys <KEYID> | base64 | tr -d '\n' | gh secret set FABLE_REPO_GPG_PRIVATE_KEY
```

## Rotation / revocation (mirrors ADR-0005)

1. Generate a new keypair.
2. Update the `FABLE_REPO_GPG_PRIVATE_KEY` secret (and optional passphrase secret).
3. Replace `keys/fable-repo-pub.asc` with the new public key and commit.
4. Trigger a new fable-repo build; the new snapshot ships the new public key.
5. Distribute the new key to Fable environments and update the trust area
   (`/data/data/com.gph.fable/files/usr/etc/apt/trusted.gpg.d/`); revoke the
   old key via its revocation certificate if compromised.
