#!/usr/bin/env python3
"""Build the /press page, web previews and ZIP downloads from the reviewed inventory.

Requires Python 3 and Pillow (previews only). Never generates or alters screenshots:
every file must match the SHA-256 recorded in approved-assets.json after review.
"""
import hashlib
import html
import json
import re
import sys
import zipfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
KIT = ROOT / "press-kit"
PREVIEWS = KIT / "Previews"
CATEGORIES = ["Screenshots", "Mockups", "Graphics", "Video", "Brand", "Information"]
ZIP_NAMES = {c: f"MeowDisplay-Press-Kit-{c}.zip" for c in CATEGORIES}
ZIP_DATE = (2026, 11, 3, 0, 0, 0)
# Over Cloudflare Pages' 25 MiB file limit, so it is published as a GitHub Release asset, not on the site.
# Each content revision gets a new asset name on the press-kit-2.0 release; superseded assets are removed.
COMPLETE_NAME = "MeowDisplay-Press-Kit-2.0-r4.zip"
COMPLETE_URL = f"https://github.com/raiseCatError/meowdisplay/releases/download/press-kit-2.0/{COMPLETE_NAME}"

COLLECTIONS = [
    ("window-view", "Window view and layouts",
     "Show individual Mac windows instead of a whole desktop, in splits or grids of up to nine panes on iPhone and iPad. Fewer, larger panes read best on a phone.",
     ["iPad-Window-View-Three-Panes", "iPhone-Window-View-Two-Panes", "iPad-Window-Picker", "iPhone-Window-Picker"]),
    ("stage-peek", "Stage Peek",
     "Swipe in from the edge to see running apps, open windows and the Mac's displays, then switch or add a pane.",
     ["iPad-Stage-Peek", "iPhone-Stage-Peek"]),
    ("input", "Touch, keyboard and typing",
     "A control tray with modifier keys and shortcuts, three touch modes, a Text Bar and Zoom While Typing.",
     ["iPhone-Typing-Zoom-While-Typing", "iPhone-Control-Tray", "iPad-Settings-Input"]),
    ("mirror-extend", "Mirror and Extend",
     "Mirror shows the display you see. Extend adds a separate display that macOS arranges like any other monitor.",
     ["iPad-Extend", "iPad-Mirror", "iPad-Settings-Display"]),
    ("mac", "The Mac app",
     "The Mac sends the picture, chooses each device's mode and keeps track of paired devices.",
     ["Mac-Overview", "Mac-Displays", "Mac-Devices"]),
    ("remote", "Remote Access and security",
     "Pairing with a matching code, TLS 1.3, and control granted per device and per session. Remote Access uses your own private network.",
     ["Mac-Remote-Access", "Mac-Input"]),
]


def fail(message):
    raise ValueError(message)


def approved():
    manifest = json.loads((ROOT / "tools/press-kit/approved-assets.json").read_text())
    items = []
    for item in manifest:
        rel = Path(item["file"])
        if rel.is_absolute() or ".." in rel.parts or rel.parts[0] not in CATEGORIES:
            fail(f"Invalid asset path: {rel}")
        path = KIT / rel
        if path.is_symlink() or not path.is_file():
            fail(f"Missing or symlinked asset: {rel}")
        if item.get("review") != "approved":
            fail(f"Unreviewed asset: {rel}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            fail(f"Asset changed since review: {rel}")
        if rel.parts[0] == "Screenshots" and not all(
                item.get(k) for k in ["device", "version", "captured", "liveSession", "privacyReviewed", "visualReviewed"]):
            fail(f"Missing live-capture provenance: {rel}")
        items.append({**item, "path": path, "stem": path.stem.replace("MeowDisplay-", "")})
    on_disk = {p.relative_to(KIT).as_posix() for c in CATEGORIES for p in (KIT / c).rglob("*")
               if p.is_file() and not p.name.startswith(".")}
    if {i["file"] for i in items} != on_disk:
        fail("press-kit/ contains files that are not in the approved inventory (or the reverse)")
    if not (KIT / "README.txt").is_file():
        fail("README.txt is required")
    return items


def preview(item, width):
    """Lightweight WebP for the page; originals stay the download."""
    out = PREVIEWS / Path(item["file"]).with_suffix(".webp")
    out.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(item["path"]) as im:
        im = im.convert("RGBA" if im.mode in ("RGBA", "LA", "P") else "RGB")
        if im.width > width:
            im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
        im.save(out, "WEBP", quality=82, method=6)
        size = im.size
    return "/" + out.relative_to(ROOT).as_posix(), size


def mb(n):
    return f"{n / 1048576:.1f} MB" if n >= 1048576 else f"{max(1, round(n / 1024))} KB"


def write_zip(name, members):
    path = KIT / name
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for arc, src in sorted(members):
            info = zipfile.ZipInfo(f"MeowDisplay-Press-Kit/{arc}", ZIP_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, src.read_bytes())
    with zipfile.ZipFile(path) as z:
        if z.testzip() is not None or len(z.namelist()) != len(members):
            fail(f"ZIP verification failed: {name}")
    return path.stat().st_size


def esc(s):
    return html.escape(str(s), quote=True)


def url(item):
    return "/press-kit/" + item["file"]


def dims(item):
    return f'{item["width"]} × {item["height"]}' if item.get("width") else ""


def figure(item, width=1400, cls="", caption=None, eager=False):
    src, (w, h) = preview(item, width)
    cap = esc(caption or item.get("caption", item["stem"]))
    load = 'fetchpriority="high"' if eager else 'loading="lazy" decoding="async"'
    meta = " · ".join(x for x in [item.get("device", ""), dims(item), mb(item["bytes"])] if x)
    return (f'<figure class="pk-fig {cls}"><a href="{url(item)}" class="pk-shot" aria-label="Open original: {cap}">'
            f'<img src="{src}" width="{w}" height="{h}" alt="{cap}" {load}></a>'
            f'<figcaption><span>{cap}</span><span class="pk-meta">{esc(meta)} · <a href="{url(item)}" download>Download</a></span></figcaption></figure>')


def section_text(md, heading):
    m = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", md, re.S | re.M)
    return m.group(1).strip() if m else fail(f"Missing section: {heading}")


def copy_block(title, text, ident):
    paras = "".join(f"<p>{esc(p)}</p>" for p in text.split("\n\n"))
    return (f'<div class="pk-copy"><div class="pk-copy-head"><h3>{esc(title)}</h3>'
            f'<button type="button" class="pk-copy-btn" data-copy="{ident}">Copy</button></div>'
            f'<div id="{ident}">{paras}</div></div>')


def page(items, zips):
    by = {i["stem"]: i for i in items}

    def cat(c):
        return [i for i in items if i["category"] == c]

    total = zips["complete"]
    md = (KIT / "Information/MeowDisplay-Descriptions.md").read_text()
    out = [f'''<section class="pk-hero"><div class="wrap">
<p class="eyebrow">Press &amp; creators</p>
<h1>MeowDisplay Press Kit</h1>
<p class="pk-lead">MeowDisplay turns an iPhone or iPad into a display for your Mac: the whole desktop, an extended desktop, or individual Mac windows you can control by touch.</p>
<p class="pk-actions"><a class="button" href="{COMPLETE_URL}">Download complete press kit</a><span class="pk-note">ZIP · {mb(total)} · {len(items)} assets plus README ({len(items) + 1} files) · hosted on GitHub<br>SHA-256 <code class="pk-sha">{hashlib.sha256((KIT / COMPLETE_NAME).read_bytes()).hexdigest()}</code></span></p>
<nav class="pk-jump" aria-label="Press kit sections"><a href="#features">Features</a><a href="#screenshots">Screenshots</a><a href="#mockups">Device mockups</a><a href="#video">B-roll</a><a href="#graphics">Graphics</a><a href="#text">Text &amp; facts</a><a href="#reviewers">Reviewer's guide</a><a href="#brand">Brand</a><a href="#downloads">Downloads</a><a href="#contact">Contact</a></nav>
</div>
<div class="pk-hero-art wrap">{figure(by["Hero-Transparent"], 2000, "pk-plain", "The MeowDisplay Mac app with two devices connected, and Mac windows side by side on an iPhone 14 Pro Max.", eager=True)}</div></section>''']

    out.append('''<section class="section pk-overview"><div class="wrap">
<p class="eyebrow">Overview</p><h2>Your Mac, on the screens you already own.</h2>
<div class="pk-modes">
<div><h3>Mirror</h3><p>The receiver shows the same Mac display you see and follows along as you work.</p></div>
<div><h3>Extend</h3><p>The receiver becomes a separate display that macOS arranges like any other monitor.</p></div>
<div><h3>Window view</h3><p>Pick individual Mac windows and arrange them in panes, instead of a shrunken desktop.</p></div>
</div>
<dl class="pk-facts">
<dt>Price</dt><dd>Free, no subscription</dd>
<dt>Source</dt><dd>Open source, <a href="https://github.com/raiseCatError/meowdisplay">GPL-3.0 on GitHub</a></dd>
<dt>Mac</dt><dd>2.0.0 released · macOS 14 or later (receiver-only app: macOS 12 or later)</dd>
<dt>iPhone &amp; iPad</dt><dd>2.0.0 released · iOS / iPadOS 16.4 or later · <a href="https://apps.apple.com/app/id6817552864">App Store</a></dd>
<dt>Android</dt><dd>Closed testing · Android 10 or later</dd>
<dt>Connections</dt><dd>USB (iPhone, iPad) · local Wi-Fi · Remote Access over your own private network, such as Tailscale</dd>
<dt>Developer</dt><dd>Jai Sukka (raiseCatError), independent</dd>
</dl></div></section>''')

    feats = ['<section class="section wash" id="features"><div class="wrap"><p class="eyebrow">Features</p><h2>Media by feature.</h2>'
             '<p class="pk-sub">Each collection starts with the clearest real screenshot. Select any image for the original file.</p>']
    for ident, title, lead, stems in COLLECTIONS:
        main, rest = by[stems[0]], [by[s] for s in stems[1:]]
        feats.append(f'<article class="pk-feature" id="f-{ident}"><div class="pk-feature-text"><h3>{esc(title)}</h3><p>{esc(lead)}</p></div>'
                     f'{figure(main, 1600)}<div class="pk-row">{"".join(figure(r, 900) for r in rest)}</div></article>')
    feats.append('</div></section>')
    out.append("".join(feats))

    shots = cat("Screenshots")
    grid = "".join(f'<div class="pk-cell" data-platform="{i["file"].split("/")[1]}">{figure(i, 900)}</div>' for i in shots)
    counts = {p: sum(1 for i in shots if i["file"].split("/")[1] == p) for p in ["iPhone", "iPad", "Mac"]}
    out.append(f'''<section class="section" id="screenshots"><div class="wrap"><p class="eyebrow">Screenshots</p><h2>Original screenshots.</h2>
<p class="pk-sub">Native-resolution captures of the released 2.0.0 apps on a physical iPhone 14 Pro Max, iPad (9th generation) and MacBook Air (M2), with demonstration content only. The only edits: two window-picker images are cropped, and the external-display thumbnail in the two Stage Peek images is blurred to remove a third-party wallpaper.</p>
<div class="pk-filter" role="group" aria-label="Filter screenshots by platform"><button type="button" aria-pressed="true" data-filter="all">All {len(shots)}</button><button type="button" aria-pressed="false" data-filter="iPhone">iPhone {counts["iPhone"]}</button><button type="button" aria-pressed="false" data-filter="iPad">iPad {counts["iPad"]}</button><button type="button" aria-pressed="false" data-filter="Mac">Mac {counts["Mac"]}</button></div>
<div class="pk-grid">{grid}</div>
<p class="pk-dl"><a href="/press-kit/{ZIP_NAMES["Screenshots"]}" download>Download all screenshots · ZIP · {mb(zips["Screenshots"])}</a></p></div></section>''')

    mocks = "".join(figure(i, 1400, "pk-plain") for i in cat("Mockups"))
    out.append(f'''<section class="section wash" id="mockups"><div class="wrap"><p class="eyebrow">Device mockups</p><h2>Real screens, real hardware.</h2>
<p class="pk-sub">Transparent PNGs: iPhone screenshots composited into Apple's official iPhone 14 Pro Max frame. The Mac app is distributed outside the App Store, so it is shown as an unframed window rather than in a MacBook frame. Apple no longer publishes an iPad (9th generation) frame, so iPad images are supplied as screenshots.</p>
<div class="pk-grid pk-grid-2">{mocks}</div>
<p class="pk-dl"><a href="/press-kit/{ZIP_NAMES["Mockups"]}" download>Download all mockups · ZIP · {mb(zips["Mockups"])}</a></p></div></section>''')

    vids = []
    for i in cat("Video"):
        if not i["file"].endswith("-1080p.mp4"):
            continue
        poster, native = by[i["stem"] + "-Poster"], by[i["stem"].replace("-1080p", "-Native")]
        pv, _ = preview(poster, 1280)
        title = i["stem"].replace("BRoll-", "").replace("-1080p", "").replace("-", " ")
        vids.append(f'<figure class="pk-fig"><video controls preload="none" playsinline muted poster="{pv}" width="1920" height="1080"><source src="{url(i)}" type="video/mp4"></video>'
                    f'<figcaption><span>{esc(title)}</span><span class="pk-meta"><a href="{url(i)}" download>1080p MP4 · {mb(i["bytes"])}</a> · <a href="{url(native)}" download>Native MP4 · {mb(native["bytes"])}</a></span></figcaption></figure>')
    out.append(f'''<section class="section" id="video"><div class="wrap"><p class="eyebrow">B-roll</p><h2>Clean footage for your edit.</h2>
<p class="pk-sub">Screen recordings of real sessions on the physical devices, trimmed only. No music, voice, captions or logos. Native-resolution and 1080p versions; see the <a href="/press-kit/Information/MeowDisplay-BRoll-Shot-List.txt">shot list</a>.</p>
<div class="pk-grid pk-grid-2">{"".join(vids)}</div>
<p class="pk-dl"><a href="/press-kit/{ZIP_NAMES["Video"]}" download>Download all video · ZIP · {mb(zips["Video"])}</a></p></div></section>''')

    gfx = "".join(figure(i, 1200, "pk-plain" if "Transparent" in i["stem"] else "") for i in cat("Graphics"))
    out.append(f'''<section class="section wash" id="graphics"><div class="wrap"><p class="eyebrow">Promotional graphics</p><h2>Ready-made compositions.</h2>
<p class="pk-sub">Layouts built from the real mockups and screenshots for articles, social posts and thumbnails. They are promotional graphics, not raw screenshots.</p>
<div class="pk-grid pk-grid-2">{gfx}</div>
<p class="pk-dl"><a href="/press-kit/{ZIP_NAMES["Graphics"]}" download>Download all graphics · ZIP · {mb(zips["Graphics"])}</a></p></div></section>''')

    caps = section_text(md, "Key capabilities")
    out.append(f'''<section class="section" id="text"><div class="wrap"><p class="eyebrow">Text &amp; facts</p><h2>Ready to quote.</h2>
<div class="pk-copies">{copy_block("One sentence", section_text(md, "One sentence"), "t1")}{copy_block("About 50 words", section_text(md, "About 50 words"), "t2")}{copy_block("About 150 words", section_text(md, "About 150 words"), "t3")}</div>
<div class="pk-two"><div><h3>Key capabilities</h3><ol>{"".join(f"<li>{esc(line[3:])}</li>" for line in caps.splitlines())}</ol></div>
<div><h3>About the developer</h3><p>{esc(section_text(md, "Developer background"))}</p></div></div>
<p class="pk-dl"><a href="/press-kit/Information/MeowDisplay-Descriptions.md" download>Full descriptions, long overview and fact sheet (Markdown)</a></p></div></section>''')

    out.append('''<section class="section wash" id="reviewers"><div class="wrap"><p class="eyebrow">Reviewer's guide</p><h2>Try it in five minutes.</h2>
<p class="pk-sub">MeowDisplay is free. No review codes, licences or accounts are needed.</p>
<div class="pk-two"><div><h3>Set up</h3><ol><li>Install MeowDisplay 2.0 for Mac from <a href="/downloads">Downloads</a> (macOS 14 or later) and grant Screen Recording; grant Accessibility to control the Mac.</li><li>Install MeowDisplay on iPhone or iPad from the <a href="https://apps.apple.com/app/id6817552864">App Store</a>.</li><li>Connect by USB or on the same Wi-Fi, confirm the matching pairing code and approve on the Mac.</li></ol>
<h3>Five-minute demo</h3><ol><li>Mirror the Mac on an iPad in landscape.</li><li>Switch the iPad to Extend and drag a window onto it.</li><li>On iPhone, open Window view and add a second window from Stage Peek.</li><li>Use Stage Peek to search and switch a pane, or show Full Desktop.</li><li>Open the keyboard, type in the Text Bar and watch Zoom While Typing.</li></ol></div>
<div><h3>Connections</h3><p><strong>USB</strong> (iPhone, iPad) needs no network. <strong>Local Wi-Fi</strong> finds devices nearby. <strong>Remote Access</strong> reaches an already paired Mac through a private-network address you provide, such as Tailscale; the address never grants trust.</p>
<h3>Security</h3><p>Pairing needs a matching code and approval on the Mac. Sessions use TLS 1.3 and pinned device identities. Control is a separate, per-session permission set on the Mac.</p>
<h3>Known issues in 2.0.0</h3><p>On iPad with the Custom control layout, rotating can leave Window view panes mis-sized until you relaunch (<a href="https://github.com/raiseCatError/meowdisplay/issues/129">#129</a>). On iPhone in landscape, the default Compact Dock in Stage Peek shows about one window at a time; choose Settings › Controls › Dock › Normal for more (<a href="https://github.com/raiseCatError/meowdisplay/issues/130">#130</a>). Android is in closed testing.</p></div></div>
<p class="pk-dl"><a href="/press-kit/Information/MeowDisplay-Reviewer-Guide.md" download>Reviewer's guide with story angles (Markdown)</a> · <a href="https://github.com/raiseCatError/meowdisplay/releases/tag/v2.0.0">2.0.0 release notes</a> · <a href="/support">Troubleshooting</a></p></div></section>''')

    icon, logo = by["AppIcon-1024"], by["Logo-512"]
    out.append(f'''<section class="section" id="brand"><div class="wrap"><p class="eyebrow">Brand</p><h2>Icon and logo.</h2>
<div class="pk-brand"><figure class="pk-swatch pk-light"><img src="{url(icon)}" width="160" height="160" alt="MeowDisplay app icon on a light background" loading="lazy"><figcaption>App icon · 1024 × 1024 PNG · <a href="{url(icon)}" download>Download</a></figcaption></figure>
<figure class="pk-swatch pk-dark"><img src="{url(logo)}" width="160" height="160" alt="MeowDisplay logo on a dark background" loading="lazy"><figcaption>Logo · 512 × 512 transparent PNG · <a href="{url(logo)}" download>Download</a></figcaption></figure></div>
<ul class="pk-rules"><li>Write <strong>MeowDisplay</strong>: one word, capital M and D.</li><li>Use the artwork as supplied; don't redraw, recolour, crop or stretch it.</li><li>Both files work on light and dark backgrounds.</li><li>Don't alter app screens or show features MeowDisplay doesn't have. Describe Android as closed testing.</li></ul>
<p class="pk-dl"><a href="/press-kit/Information/MeowDisplay-Usage-and-Brand-Guidelines.md" download>Usage permission, brand and trademark notes</a> · <a href="/press-kit/Information/MeowDisplay-Asset-Notes.md" download>Asset provenance</a></p></div></section>''')

    labels = {"Screenshots": "Original screenshots · PNG", "Mockups": "Device mockups · transparent PNG", "Graphics": "Promotional graphics · PNG",
              "Video": "B-roll · MP4 and posters", "Brand": "Icon and logo · PNG", "Information": "Descriptions, reviewer's guide, guidelines · Markdown, TXT"}
    rows = "".join(f'<tr><th scope="row">{esc(labels[c])}</th><td>{len(cat(c)) + 1} files (incl. README)</td><td>{mb(zips[c])}</td><td><a href="/press-kit/{ZIP_NAMES[c]}" download>Download ZIP</a></td></tr>' for c in CATEGORIES)
    out.append(f'''<section class="section wash" id="downloads"><div class="wrap"><p class="eyebrow">Downloads</p><h2>Take what you need.</h2>
<table class="pk-table"><thead><tr><th scope="col">Collection</th><th scope="col">Files</th><th scope="col">Size</th><th scope="col"><span class="visually-hidden">Download</span></th></tr></thead><tbody>
<tr class="pk-total"><th scope="row">Complete press kit</th><td>{len(items) + 1} files (incl. README)</td><td>{mb(total)}</td><td><a href="{COMPLETE_URL}">Download ZIP</a></td></tr>{rows}</tbody></table></div></section>''')

    out.append('''<section class="section" id="contact"><div class="wrap pk-contact"><p class="eyebrow">Contact</p><h2>Covering MeowDisplay?</h2>
<p>For interviews, questions or additional screenshots, email <a href="mailto:j@raisecaterror.com">j@raisecaterror.com</a>.</p>
<p>Bug reports and public questions: <a href="https://github.com/raiseCatError/meowdisplay/issues">github.com/raiseCatError/meowdisplay/issues</a></p>
<p class="pk-links"><a href="https://meowdisplay.app">meowdisplay.app</a><a href="/features">Features</a><a href="/docs">Setup</a><a href="/downloads">Downloads</a><a href="https://apps.apple.com/app/id6817552864">App Store</a><a href="https://github.com/raiseCatError/meowdisplay">Source code</a></p></div></section>''')

    out.append('''<script>
document.querySelectorAll('.pk-filter button').forEach(function(b){b.addEventListener('click',function(){
 var f=b.dataset.filter;document.querySelectorAll('.pk-filter button').forEach(function(x){x.setAttribute('aria-pressed',x===b)});
 document.querySelectorAll('.pk-cell').forEach(function(c){c.hidden=!(f==='all'||c.dataset.platform===f)})})});
document.querySelectorAll('.pk-copy-btn').forEach(function(b){b.addEventListener('click',function(){
 var t=document.getElementById(b.dataset.copy).innerText.trim();
 (navigator.clipboard?navigator.clipboard.writeText(t):Promise.reject()).then(function(){b.textContent='Copied'},function(){b.textContent='Select and copy'});
 setTimeout(function(){b.textContent='Copy'},2000)})});
</script>''')
    return "\n".join(out)


STYLE = """
.pk-hero{padding:72px 0 0;text-align:center}.pk-hero h1{font-size:clamp(2.6rem,6vw,4.5rem);line-height:1.05;letter-spacing:-.045em;margin:0 0 18px}
.pk-lead{font-size:clamp(1.1rem,2vw,1.35rem);line-height:1.5;color:var(--muted);max-width:44rem;margin:0 auto}
.pk-actions{display:flex;gap:14px;align-items:center;justify-content:center;flex-wrap:wrap;margin:28px 0 18px}.pk-note{color:var(--muted);font-size:14px}.pk-sha{font-size:11px;word-break:break-all}
.pk-jump{display:flex;flex-wrap:wrap;justify-content:center;gap:6px 18px;font-size:14px;margin-bottom:36px}
.pk-hero-art figcaption{text-align:center;align-items:center}
.pk-sub{color:var(--muted);max-width:46rem;line-height:1.6;margin-bottom:32px}
.pk-modes{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:28px;margin:28px 0 40px}.pk-modes h3{margin:0 0 6px}.pk-modes p{color:var(--muted);line-height:1.55;margin:0}
.pk-facts{display:grid;grid-template-columns:max-content 1fr;gap:12px 28px;border-top:1px solid var(--line);padding-top:24px;margin:0}.pk-facts dt{font-weight:600}.pk-facts dd{margin:0;color:var(--muted)}
.pk-fig{margin:0;min-width:0}.pk-fig img,.pk-fig video{display:block;width:100%;height:auto;border-radius:12px;background:#0b0b0c}
.pk-plain img{background:none;border-radius:0}
.pk-fig figcaption{display:flex;flex-direction:column;gap:3px;font-size:14px;line-height:1.45;margin-top:10px}.pk-meta{color:var(--muted);font-size:13px}
.pk-feature{margin-top:64px}.pk-feature-text{max-width:40rem;margin-bottom:20px}.pk-feature-text h3{font-size:clamp(1.5rem,3vw,2rem);letter-spacing:-.02em;margin:0 0 8px}.pk-feature-text p{color:var(--muted);line-height:1.55;margin:0}
.pk-row{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:24px;margin-top:24px}.pk-feature>.pk-fig img{width:auto;max-width:100%;max-height:640px;margin-inline:auto}.pk-feature>.pk-fig figcaption{max-width:46rem}
.pk-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:28px}.pk-grid-2{grid-template-columns:repeat(2,minmax(0,1fr))}.pk-cell[hidden]{display:none}
.pk-filter{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:24px}.pk-filter button{font:inherit;font-size:14px;border:1px solid var(--line);background:none;color:inherit;border-radius:999px;padding:6px 14px;cursor:pointer}
.pk-filter button[aria-pressed=true]{background:var(--ink);color:var(--wash);border-color:var(--ink)}
.pk-dl{margin-top:28px;font-size:15px}
.pk-copies{display:grid;gap:20px;margin:24px 0 40px}.pk-copy{border:1px solid var(--line);border-radius:14px;padding:20px 22px}.pk-copy-head{display:flex;justify-content:space-between;align-items:center;gap:12px}
.pk-copy h3{margin:0;font-size:16px}.pk-copy p{line-height:1.6;margin:10px 0 0}.pk-copy-btn{font:inherit;font-size:13px;border:1px solid var(--line);background:none;color:var(--blue);border-radius:999px;padding:4px 12px;cursor:pointer}
.pk-two{display:grid;grid-template-columns:1fr 1fr;gap:40px}.pk-two li,.pk-two p{line-height:1.6}.pk-two h3{margin:24px 0 8px}.pk-two h3:first-child{margin-top:0}
.pk-brand{display:grid;grid-template-columns:1fr 1fr;gap:24px;margin:24px 0}.pk-swatch{margin:0;border-radius:16px;padding:48px 24px 24px;text-align:center}.pk-swatch img{width:160px;height:160px}
.pk-swatch figcaption{margin-top:24px;font-size:14px}.pk-light{background:#f5f5f7;color:#1d1d1f}.pk-dark{background:#1c1c1e;color:#f5f5f7}.pk-dark a{color:#4da3ff}.pk-light a{color:#0066cc}
.pk-rules{line-height:1.7;padding-left:1.2em}
.pk-table{width:100%;border-collapse:collapse;font-size:15px}.pk-table th,.pk-table td{text-align:left;padding:14px 10px;border-bottom:1px solid var(--line)}.pk-table thead th{font-size:13px;color:var(--muted);font-weight:600}.pk-total th,.pk-total td{font-weight:600}
.pk-contact{text-align:center}.pk-contact p{font-size:18px;line-height:1.6}.pk-links{display:flex;flex-wrap:wrap;justify-content:center;gap:8px 20px;font-size:15px!important;margin-top:24px}
.visually-hidden{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
@media (max-width:820px){.pk-row{grid-template-columns:repeat(2,minmax(0,1fr))}.pk-modes,.pk-two,.pk-brand{grid-template-columns:1fr}.pk-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.pk-grid-2{grid-template-columns:1fr}.pk-hero{padding-top:48px}}
@media (max-width:520px){.pk-grid,.pk-row{grid-template-columns:1fr}.pk-facts{grid-template-columns:1fr;gap:2px}.pk-facts dd{margin-bottom:10px}.pk-table th,.pk-table td{padding:10px 4px;font-size:14px}.pk-table thead{display:none}}
"""


def main():
    items = approved()  # Fail before writing anything when review is pending.
    readme = KIT / "README.txt"
    zips = {}
    for c in CATEGORIES:
        members = [(i["file"], i["path"]) for i in items if i["category"] == c] + [("README.txt", readme)]
        zips[c] = write_zip(ZIP_NAMES[c], members)
    zips["complete"] = write_zip(COMPLETE_NAME, [(i["file"], i["path"]) for i in items] + [("README.txt", readme)])
    template = (ROOT / "tools/press-kit/press.template.html").read_text()
    html_out = template.replace("{{STYLE}}", STYLE.strip()).replace("{{CONTENT}}", page(items, zips))
    (ROOT / "press.html").write_text(html_out)
    print(f"Built press.html, {len(CATEGORIES) + 1} ZIPs ({zips['complete'] / 1048576:.1f} MB complete) and previews for {len(items)} assets")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, FileNotFoundError) as error:
        sys.exit(f"Press kit not ready: {error}")
