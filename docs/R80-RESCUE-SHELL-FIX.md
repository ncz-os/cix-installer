# R80 rescue shell interactivity fix

The first rescue image exposed port 2323, but commands sent via `nc` did not reach the shell because the pipeline was one-way:

```sh
{ /bin/sh -i; } 2>&1 | nc -l -p 2323
```

Fixed in `tools/rescue/build-r80-rescue-iso.py` by using a FIFO-backed BusyBox `nc` shell:

```sh
rm -f /tmp/rescue-shell.in
mkfifo /tmp/rescue-shell.in
{ echo "NCZ R80 rescue shell. Try: /rescue-tools/status"; /bin/sh -i < /tmp/rescue-shell.in 2>&1; } | nc -l -p 2323 > /tmp/rescue-shell.in
```

Rebuilt artifacts:

```text
/Users/jperlow/ncz-r80-rescue-cixmini.img
  sha256: da4de6d8f5af93b4489591ea7164ce1b8e0a66abfb401a8f5d27725bcdd9663a
  verified: MBR + FAT32 NCZRESCUE + rescue shell FIFO code present

/Users/jperlow/ncz-r80-rescue-cixmini.iso
  sha256: 49c7f4b0e575af5efe6132c043ff70b9c8249ce30b343d5bf21541395db3ae8b
```

Use `.img` for Balena Etcher.
