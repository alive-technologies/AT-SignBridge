# AT-SignBridge

Use your bank's **USB token / qualified certificate** (KIBS, etc.) for e-banking **on Linux**: no Windows VM needed.

Many banks in North Macedonia and Serbia (on the Asseco SEE e-banking platform) sign logins and payments through the
**"Aseba Crypto Signer"** Chrome extension plus a small program that the bank ships **for Windows only**. AT-SignBridge
runs that same official program under [Wine](https://www.winehq.org/), with [OpenSC](https://github.com/OpenSC/OpenSC) as
the token driver, and connects it to your Linux browser. Your bank still sees its own signer, so signatures are identical
to Windows.

> Made by Alive Technologies. Not affiliated with Asseco SEE, KIBS or any bank. Use at your own risk.

## Tested

| Bank | Token | Login | Payments |
|------|-------|-------|----------|
| NLB Banka (nlbproklik.com.mk) | KIBS, SafeNet eToken 5110 | ✅ | ✅ |

Other sites that use the same extension (from its own allow-list) *should* work too, but are untested:
ibank.com.mk, secure.24x7.com.mk, silkroad.24x7.com.mk, obsgnet.com.mk, netbanking.mk, e-unibank.mk,
ebank.capitalbank.com.mk, ebank.altabanka.com.mk, ebank.mbank.mk, portal.mbdp.com.mk, secure.silkroadbank.com.mk,
online.24x7.rs, secure.bancaintesa.rs, auth.*.open-bank.io.
Please open an issue or PR to add your bank/token to the table.

## Requirements

- Ubuntu / Debian (x86-64). Other distros work if you install the same packages.
- Google Chrome / Chromium / Brave / Edge / Vivaldi installed as a normal package (**not** snap/flatpak).
  Firefox works only from the .deb/Mozilla repo, not the default snap.
- The Chrome extension **"Aseba Crypto Signer"** (your bank's login page links to it).
- The signer installer **from your bank** (`aseba-crypto-signer-*.msi`), downloaded from the bank's "install component"
  pop-up or support page. It is not redistributed here.

## Install

```bash
sudo dpkg --add-architecture i386 && sudo apt update && \
  sudo apt install -y wine64 wine msitools curl python3 pcscd libccid opensc && \
  sudo systemctl enable --now pcscd.socket

git clone https://github.com/alive-technologies/AT-SignBridge.git && cd AT-SignBridge
./install.sh ~/Downloads/aseba-crypto-signer-1.0.1.15-r3.msi
```

The installer:

1. extracts the signer from your bank's `.msi` into `~/.local/share/at-signbridge/`
2. creates a dedicated Wine prefix there
3. downloads OpenSC for Windows and installs its PKCS#11 driver under every driver name the signer looks for
   (`eTPKCS11.dll`, `gclib.dll`, `eps2003csp11.dll`, `aetpkss1.dll`, …)
4. registers the native-messaging host for every browser it finds
5. installs the `at-signbridge` command and runs a self-test (no PIN needed)

Check your token is visible to Linux: `pkcs11-tool -L` should list it.

## Use

Plug in the token, open your bank, log in / sign. The bank's own signer window pops up for the PIN (it may take a few
seconds the first time). Unplug the token when done.

```text
at-signbridge status     # on/off, browsers, is the token plugged in
at-signbridge off        # browsers can no longer reach the signer
at-signbridge on
at-signbridge test       # version check, no PIN
at-signbridge log        # last messages between bank page and signer (no PINs)
at-signbridge uninstall
```

## Token not supported by OpenSC?

Use your token vendor's **Windows 64-bit** PKCS#11 DLL instead:

```bash
./install.sh ~/Downloads/aseba-crypto-signer-*.msi --pkcs11 /path/to/vendor-pkcs11.dll
```

## Troubleshooting

- **Bank says the component is not installed**: `at-signbridge status` must say ON; `at-signbridge test` must print a
  version. Restart the browser once after the first install.
- **Signer says no token / no certificate**: `pkcs11-tool -L` on Linux must see it; if not, `systemctl status pcscd`
  and re-plug the token.
- **Bank asks you to update the component**: download the new `.msi` and run `./install.sh` again.
- Look at `at-signbridge log`, and the signer's own log in
  `~/.local/share/at-signbridge/wineprefix/drive_c/users/$USER/AppData/Local/Asseco-SEE/`.

## How it works

```
bank page ──postMessage──▶ Aseba extension ──native messaging (stdio JSON)──▶ run.sh ▶ relay.py
     ▶ wine aseba_crypto_signer.exe ▶ eTPKCS11.dll (= OpenSC) ▶ Wine winscard ▶ pcscd ▶ USB token
```

The relay only forwards and logs; the PIN is typed into the signer's own window and never touches the relay.
