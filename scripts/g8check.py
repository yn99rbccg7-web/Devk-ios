#!/usr/bin/env python3
"""G8: does the binary's entitlements match its embedded profile's team?
Usage: g8check.py <file.app> | g8check.py <file.ipa>
exit 0 PASS, 1 FAIL, 2 unreadable."""
import plistlib, re, sys, os, subprocess, tempfile, zipfile, shutil

def profile_of(app):
    p = os.path.join(app, "embedded.mobileprovision")
    if not os.path.exists(p): return None
    m = re.search(rb"<\?xml.*?</plist>", open(p, "rb").read(), re.S)
    return plistlib.loads(m.group(0)) if m else None

def main():
    tgt = sys.argv[1]; tmp = None
    if tgt.lower().endswith(".ipa"):
        tmp = tempfile.mkdtemp()
        zipfile.ZipFile(tgt).extractall(tmp)
        apps = [os.path.join(dp, d) for dp, dn, fn in os.walk(tmp) for d in dn if d.endswith(".app")]
        if not apps: print("no .app inside", tgt); return 2
        app = apps[0]
    else:
        app = tgt
    prof = profile_of(app)
    if prof is None: print("no embedded.mobileprovision in", app); return 2
    pe = prof.get("Entitlements", {}); pt = (prof.get("TeamIdentifier") or [""])[0]
    pai = pe.get("application-identifier", "")
    out = subprocess.run(["codesign", "-d", "--entitlements", ":-", app], capture_output=True)
    try: be = plistlib.loads(out.stdout)
    except Exception: be = {}
    bt = be.get("com.apple.developer.team-identifier", "")
    bai = be.get("application-identifier", "")
    print("profile expires :", prof.get("ExpirationDate"))
    print("profile team    :", pt)
    print("profile appid   :", pai)
    print("binary  team    :", bt)
    print("binary  appid   :", bai)
    print("profile get-task-allow:", pe.get("get-task-allow"))
    print("binary  get-task-allow:", be.get("get-task-allow"))
    print()
    ok = True
    if not bt: print("FAIL binary carries no team-identifier"); ok = False
    if bt and bt != pt: print("FAIL binary team", bt, "!= profile team", pt); ok = False
    if not bai: print("FAIL binary carries no application-identifier"); ok = False
    if bai and pai and bai != pai: print("FAIL binary appid", bai, "!= profile appid", pai); ok = False
    print("G8 VERDICT:", "PASS" if ok else "FAIL")
    if tmp: shutil.rmtree(tmp, ignore_errors=True)
    return 0 if ok else 1

sys.exit(main())
