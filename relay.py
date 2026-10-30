#!/usr/bin/env python3
"""AT-SignBridge browser native-messaging relay.

Runs the bank's real Windows "Aseba Crypto Signer" under Wine and forwards the
length-prefixed JSON frames in both directions, logging a shortened copy of
each frame to relay.log. PINs never pass through here: the signer asks for the
PIN in its own window.
"""
import json
import os
import struct
import subprocess
import sys
import threading
import time

D = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(D, "relay.log")
env = dict(os.environ, WINEPREFIX=os.path.join(D, "wineprefix"), WINEDEBUG="-all")


def log(*p):
    with open(LOG, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + " ".join(map(str, p)) + "\n")


def short(m):
    return {k: (v[:80] + f"...({len(v)})" if isinstance(v, str) and len(v) > 100 else v) for k, v in m.items()}


def pump(src, dst, tag):
    while True:
        h = src.read(4)
        if len(h) < 4:
            log(tag, "EOF")
            if tag == "REQ":
                dst.close()
            break
        body = src.read(struct.unpack("<I", h)[0])
        try:
            log(tag, json.dumps(short(json.loads(body)), ensure_ascii=False))
        except Exception:
            log(tag, "unparsable", len(body))
        dst.write(h + body)
        dst.flush()


log("start", sys.argv[1:])
p = subprocess.Popen(["wine", os.path.join(D, "signer", "aseba_crypto_signer.exe")] + sys.argv[1:],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     cwd=os.path.join(D, "signer"), env=env)
threading.Thread(target=pump, args=(sys.stdin.buffer, p.stdin, "REQ"), daemon=True).start()
pump(p.stdout, sys.stdout.buffer, "RESP")
p.wait()
log("exit", p.returncode)
os._exit(0)
