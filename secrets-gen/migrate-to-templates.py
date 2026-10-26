#!/usr/bin/env python3
"""One-shot: per-stack .sops.env (dotenv) -> secrets.sops.json + secrets/shared.sops.json.

Delete after the cutover. Re-runnable: it reads only the old layout and writes
only the new one, so it can be run again against main's then-current files
right before the gitops-migration branch merges.

What moves where:
  * every stack .sops.env becomes stacks/<n>/secrets.sops.json holding the
    STORED keys only — keys an env.nix builds (DATABASE_URL around a password,
    an OIDC secret from the shared file) are dropped, as are the --drop keys;
  * every key an env.nix reads with `shared` moves to the shared JSON, taking
    its value from the VPS file (the side that registers the OIDC client) and
    leaving the VPS file;
  * --ci NAME=FILE:KEY folds a dotenv credential into the services-VM yaml.

It verifies before writing anything: for every built key, the value the new
template renders must equal the value compose sees today. A mismatch is a twin
that had already drifted; it is reported by key name and lengths (never the
value) and the run refuses unless that key is listed in --accept-drift.

Needs the age key for the inputs (SOPS_AGE_KEY_FILE) and only the public
recipient for the outputs. Values never reach argv or stdout.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

MARK = re.compile(r"@@(S|H):([A-Za-z0-9_]+)@@")


def sops_decrypt(path, fmt):
    return subprocess.run(
        ["sops", "decrypt", "--input-type", fmt, "--output-type", fmt, path],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def sops_encrypt(plain_text, fmt, recipient, out_path):
    # Plaintext goes through a 0600 file in the scratch dir, never argv.
    with tempfile.NamedTemporaryFile("w", dir=SCRATCH, delete=False) as f:
        f.write(plain_text)
        tmp = f.name
    try:
        enc = subprocess.run(
            ["sops", "encrypt", "--age", recipient, "--input-type", fmt, "--output-type", fmt, tmp],
            check=True,
            capture_output=True,
            text=True,
            # Outside the repo: sops looks for .sops.yaml upward from its cwd,
            # and no creation rule matches a scratch path. --age names the
            # recipient explicitly instead.
            cwd=SCRATCH,
        ).stdout
    finally:
        os.unlink(tmp)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w") as f:
        f.write(enc)


def compose_value(raw, where):
    """The value docker compose takes from a dotenv line's right-hand side."""
    if len(raw) >= 2 and raw[0] == raw[-1] == "'":
        return raw[1:-1]
    if len(raw) >= 2 and raw[0] == raw[-1] == '"':
        die(f"{where}: double-quoted value — escapes would need compose's rules; convert by hand")
    v = raw.split(" #", 1)[0].strip()
    if "$" in v:
        die(f"{where}: unquoted value containing '$' — compose interpolates it today; fix by hand first")
    return v


def parse_dotenv(text, where):
    out = {}
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not m:
            die(f"{where}:{n}: not a KEY=value line")
        k, raw = m.groups()
        if k.startswith("sops_"):
            continue
        out[k] = compose_value(raw, f"{where}:{k}")
    return out


def top_level_yaml_scalars(text):
    """KEY: value pairs at column 0 — the shape of the hosts' secrets files."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s?(.*)$", line)
        if m and m.group(2) not in ("", "|", "|-", ">", ">-"):
            v = m.group(2)
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                v = v[1:-1]
            out[m.group(1)] = v
    return out


def drop_yaml_keys(text, keys):
    """Remove top-level scalar KEY lines and the comment block directly above."""
    lines = text.splitlines()
    keep = [True] * len(lines)
    for i, line in enumerate(lines):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", line)
        if m and m.group(1) in keys:
            keep[i] = False
            j = i - 1
            while j >= 0 and lines[j].startswith("#"):
                keep[j] = False
                j -= 1
    return "\n".join(l for l, k in zip(lines, keep) if k) + "\n"


def drop_yaml_block_keys(text, keys):
    """Remove top-level KEY entries — scalar or block scalar (`KEY: |` plus its
    indented lines) — and the comment block directly above each."""
    lines = text.splitlines()
    keep = [True] * len(lines)
    i = 0
    while i < len(lines):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):", lines[i])
        if m and m.group(1) in keys:
            keep[i] = False
            j = i - 1
            while j >= 0 and lines[j].startswith("#"):
                keep[j] = False
                j -= 1
            i += 1
            while i < len(lines) and (lines[i].startswith((" ", "\t")) or lines[i] == ""):
                keep[i] = False
                i += 1
            continue
        i += 1
    return "\n".join(l for l, k in zip(lines, keep) if k) + "\n"


def die(msg):
    print(f"migrate-to-templates: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True, help="JSON {stack: {KEY: template-with-markers}}")
    ap.add_argument("--recipient", required=True)
    ap.add_argument("--stack", action="append", default=[], help="NAME=IN.sops.env:OUT.sops.json")
    ap.add_argument("--drop", action="append", default=[], help="NAME:KEY — inert key, dropped")
    ap.add_argument("--vps-in", required=True)
    ap.add_argument("--vps-out", required=True)
    ap.add_argument("--shared-out", required=True)
    ap.add_argument("--vm-in", required=True)
    ap.add_argument("--vm-out", required=True)
    ap.add_argument("--ci", action="append", default=[], help="NAME=IN.sops.env:KEY")
    ap.add_argument("--ci-literal", action="append", default=[], help="NAME=value (fixtures only)")
    ap.add_argument("--vm-drop", action="append", default=[], help="KEY removed from the VM yaml")
    ap.add_argument("--accept-drift", action="append", default=[], help="NAME:KEY")
    ap.add_argument("--accept-all-drift", action="store_true", help="fixtures only: twins were never equal there")
    ap.add_argument("--add-key", action="append", default=[], help="NAME:KEY=value — a new stored key (placeholder)")
    a = ap.parse_args()

    spec = json.load(open(a.spec))
    drops = {}
    for d in a.drop:
        s, k = d.split(":", 1)
        drops.setdefault(s, set()).add(k)
    accept = set(a.accept_drift)

    # Shared values come from the VPS file.
    vps_plain = sops_decrypt(a.vps_in, "yaml")
    vps = top_level_yaml_scalars(vps_plain)
    shared_keys = sorted({k for t in spec.values() for v in t.values() for kind, k in MARK.findall(v) if kind == "H"})
    missing = [k for k in shared_keys if k not in vps]
    if missing:
        die(f"shared keys absent from {a.vps_in}: {', '.join(missing)}")
    shared = {k: vps[k] for k in shared_keys}

    problems = []
    outputs = []
    for s_arg in a.stack:
        name, paths = s_arg.split("=", 1)
        src, dst = paths.split(":", 1)
        old = parse_dotenv(sops_decrypt(src, "dotenv"), src)
        built = spec.get(name, {})
        stored = {k: v for k, v in old.items() if k not in built and k not in drops.get(name, set())}

        for k, tpl in built.items():
            if k not in old:
                problems.append(f"{name}:{k} is built by env.nix but absent from {src}")
                continue

            def sub(m):
                kind, key = m.groups()
                if kind == "S":
                    if key not in stored:
                        problems.append(f"{name}:{k} reads secret {key}, which is not stored")
                        return ""
                    return stored[key]
                return shared[key]

            new = MARK.sub(sub, tpl)
            if new != old[k]:
                tag = f"{name}:{k}"
                msg = f"{tag} drifted: today {len(old[k])} chars, template renders {len(new)}"
                if tag in accept or a.accept_all_drift:
                    print(f"  accepted  {msg}")
                else:
                    problems.append(msg + " (pass --accept-drift to take the template's value)")
        for k in drops.get(name, set()):
            if k not in old:
                problems.append(f"{name}:{k} listed in --drop but absent")
        for k, v in stored.items():
            if "\n" in v or "'" in v:
                problems.append(f"{name}:{k} holds a newline or a single quote — the template cannot quote it")
        for ak in a.add_key:
            s_name, kv = ak.split(":", 1)
            if s_name == name:
                k, v = kv.split("=", 1)
                if k in stored or k in built:
                    die(f"--add-key {name}:{k}: the key already exists")
                stored[k] = v
        outputs.append((name, dst, stored, sorted(built), sorted(drops.get(name, set()))))

    for k, v in shared.items():
        if "\n" in v or "'" in v:
            problems.append(f"shared:{k} holds a newline or a single quote")

    if problems:
        for p in problems:
            print(f"  PROBLEM   {p}", file=sys.stderr)
        die(f"{len(problems)} problem(s); nothing written")

    # Write: stacks, shared, VPS minus shared, VM plus CI.
    for name, dst, stored, built, dropped in outputs:
        sops_encrypt(json.dumps(stored, indent=2) + "\n", "json", a.recipient, dst)
        extra = (f"; built: {', '.join(built)}" if built else "") + (f"; dropped: {', '.join(dropped)}" if dropped else "")
        print(f"  wrote     {dst} ({len(stored)} keys{extra})")

    sops_encrypt(json.dumps(shared, indent=2) + "\n", "json", a.recipient, a.shared_out)
    print(f"  wrote     {a.shared_out} ({len(shared)} keys)")

    sops_encrypt(drop_yaml_keys(vps_plain, set(shared_keys)), "yaml", a.recipient, a.vps_out)
    print(f"  wrote     {a.vps_out} (-{len(shared_keys)} keys moved to shared)")

    vm_plain = sops_decrypt(a.vm_in, "yaml")
    if a.vm_drop:
        vm_plain = drop_yaml_block_keys(vm_plain, set(a.vm_drop))
    have = top_level_yaml_scalars(vm_plain)
    add = []
    for c in a.ci:
        name, rest = c.split("=", 1)
        f, key = rest.split(":", 1)
        add.append((name, parse_dotenv(sops_decrypt(f, "dotenv"), f)[key]))
    for c in a.ci_literal:
        name, val = c.split("=", 1)
        add.append((name, val))
    for name, val in add:
        if name in have:
            die(f"{a.vm_in} already has {name}")
        vm_plain = vm_plain.rstrip("\n") + f"\n{name}: {json.dumps(val)}\n"
    sops_encrypt(vm_plain, "yaml", a.recipient, a.vm_out)
    print(f"  wrote     {a.vm_out} (+{len(add)}: {', '.join(n for n, _ in add)})")


if __name__ == "__main__":
    SCRATCH = tempfile.mkdtemp(dir=os.environ.get("XDG_RUNTIME_DIR") or "/dev/shm")
    os.chmod(SCRATCH, 0o700)
    try:
        main()
    finally:
        for f in os.listdir(SCRATCH):
            os.unlink(os.path.join(SCRATCH, f))
        os.rmdir(SCRATCH)
