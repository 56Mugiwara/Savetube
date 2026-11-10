import os
import sys
import threading
import time
import subprocess
import json
import math
import tkinter as tk
from tkinter import ttk, messagebox
import tkinter.font as tkfont
import yt_dlp

# The glass interface needs Pillow + NumPy  ->  pip install pillow numpy
try:
    import numpy as np
    from PIL import Image, ImageTk, ImageDraw
except ImportError:
    _r = tk.Tk()
    _r.withdraw()
    messagebox.showerror(
        "Missing modules",
        "The glass interface needs Pillow and NumPy.\n\nInstall them with:\n\npip install pillow numpy",
    )
    sys.exit(1)

# Optional imports for embedded media playback
try:
    import pygame
    pygame.mixer.init()
    HAS_PYGAME = True
except ImportError:
    HAS_PYGAME = False

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# Folder paths
MP4_DIR = os.path.join(BASE_DIR, ".Dmp4")
MP3_DIR = os.path.join(BASE_DIR, ".Dmp3")

os.makedirs(MP4_DIR, exist_ok=True)
os.makedirs(MP3_DIR, exist_ok=True)

# Global player state
current_playing_file = None
is_paused = False

# ==============================================================================
# BACKGROUND WORKER LOGIC (.Dmp4 & .Dmp3 scripts)
# ==============================================================================

def run_background_script(script_path):
    """Runs a target Python script infinitely in a background loop."""
    while True:
        try:
            if os.path.exists(script_path):
                # Run the script using the current Python interpreter
                subprocess.run([sys.executable, script_path], check=False)
            else:
                # If the script file isn't found yet, wait a bit before checking again
                time.sleep(5)
        except Exception as e:
            print(f"Error running {script_path}: {e}")
            time.sleep(5)

def start_background_scripts():
    """Starts both destination scripts as background daemon threads."""
    mp4_script = os.path.join(MP4_DIR, "Mp4DupliDestination.py")
    mp3_script = os.path.join(MP3_DIR, "Mp3DupliDestination.py")

    # Start MP4 background script thread
    t_mp4 = threading.Thread(target=run_background_script, args=(mp4_script,), daemon=True)
    t_mp4.start()

    # Start MP3 background script thread
    t_mp3 = threading.Thread(target=run_background_script, args=(mp3_script,), daemon=True)
    t_mp3.start()

# ==============================================================================
# DOWNLOAD LOGIC
# ==============================================================================

# ---- download progress plumbing (yt-dlp hooks -> UI) --------------------------
PROG = {"mode": "idle", "value": 0.0, "stage": 0, "stages": 1, "seen": [], "fmt": ""}

def _ui(fn):
    """Run fn on the Tk main thread (the hooks fire on the download thread)."""
    try:
        root.after(0, fn)
    except Exception:
        pass

def _progress_hook(d):
    st = d.get("status")
    info = d.get("info_dict") or {}
    fn = d.get("filename") or info.get("filename") or ""
    exp = len(info.get("requested_formats") or []) or 1
    if st == "downloading":
        done = d.get("downloaded_bytes") or 0
        total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
        frac = (done / total) if total else 0.0
        speed, eta = d.get("speed"), d.get("eta")
        _ui(lambda: progress_update(fn, frac, exp, speed, eta))
    elif st == "finished":
        _ui(lambda: progress_update(fn, 1.0, exp, None, None))

def _pp_hook(d):
    if d.get("status") == "started":
        name = str(d.get("postprocessor", ""))
        text = ("Converting to MP3…" if "ExtractAudio" in name else
                "Merging video and audio…" if "Merger" in name else "Finishing up…")
        _ui(lambda: progress_busy(text))

def process_download():
    url = url_entry.get().strip()
    selected_format = format_combobox.get()

    if not url:
        messagebox.showwarning("Input Error", "Please paste a video link first.")
        return

    if PROG["mode"] in ("progress", "busy"):
        status_label.config(text="A download is already running...")
        return

    status_label.config(text="Processing download... Please wait.")
    stages = 2 if selected_format == "Both" else 1
    progress_begin(0, stages, "MP4" if selected_format in ["MP4", "Both"] else "MP3")
    root.update()

    def run_thread():
        try:
            n = 0
            if selected_format in ["MP4", "Both"]:
                status_label.config(text="Downloading MP4...")
                download_mp4(url)
                n += 1

            if selected_format in ["MP3", "Both"]:
                if n:
                    _ui(lambda: progress_begin(1, stages, "MP3"))
                status_label.config(text="Downloading MP3...")
                download_mp3(url)

            status_label.config(text="Download success")
            refresh_file_list()
            _ui(lambda: progress_finish(True))
        except Exception as e:
            status_label.config(text="Error occurred.")
            _ui(lambda: progress_finish(False))
            messagebox.showerror("Error", str(e))

    threading.Thread(target=run_thread, daemon=True).start()

def download_mp4(url):
    ydl_opts = {
        'format': 'bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best',
        'merge_output_format': 'mp4',
        'outtmpl': os.path.join(MP4_DIR, '%(title)s.%(ext)s'),
        'progress_hooks': [_progress_hook],
        'postprocessor_hooks': [_pp_hook],
        'ffmpeg_location': BASE_DIR
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        ydl.download([url])

def download_mp3(url):
    ydl_opts = {
        'format': 'bestaudio/best',
        'postprocessors': [{
            'key': 'FFmpegExtractAudio',
            'preferredcodec': 'mp3',
            'preferredquality': '192',
        }],
        'outtmpl': os.path.join(MP3_DIR, '%(title)s.%(ext)s'),
        'progress_hooks': [_progress_hook],
        'postprocessor_hooks': [_pp_hook],
        'ffmpeg_location': BASE_DIR
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        ydl.download([url])

# ==============================================================================
# IN-APP MEDIA PLAYER LOGIC
# ==============================================================================

def play_selected_file(event=None):
    global current_playing_file, is_paused

    selected = file_listbox.curselection()
    if not selected:
        return

    item_text = file_listbox.get(selected[0])

    if item_text.startswith("[MP4]"):
        filename = item_text.replace("[MP4] ", "")
        file_path = os.path.join(MP4_DIR, filename)
        is_video = True
    else:
        filename = item_text.replace("[MP3] ", "")
        file_path = os.path.join(MP3_DIR, filename)
        is_video = False

    if not os.path.exists(file_path):
        messagebox.showerror("File Error", "File not found.")
        return

    # Audio Playback via Pygame
    if not is_video:
        if HAS_PYGAME:
            pygame.mixer.music.load(file_path)
            pygame.mixer.music.play()
            current_playing_file = file_path
            is_paused = False
            player_status_label.config(text=f"Playing Audio: {filename}")
            media_canvas.itemconfig(canvas_text, text=f"🎵 Audio Playing:\n{filename}")
        else:
            messagebox.showinfo("Module Missing", "Install 'pygame' using 'pip install pygame' for embedded audio playback.")
    else:
        # Video placeholder notification inside the embedded screen frame
        player_status_label.config(text=f"Loaded Video: {filename}")
        media_canvas.itemconfig(canvas_text, text=f"🎬 Video Loaded:\n{filename}\n(Ready in App Screen)")

def open_selected_file(event=None):
    """Open the selected MP3/MP4 with the system's default player."""
    selected = file_listbox.curselection()
    if not selected:
        return
    item_text = file_listbox.get(selected[0])
    if item_text.startswith("[MP4]"):
        file_path = os.path.join(MP4_DIR, item_text.replace("[MP4] ", "", 1))
    else:
        file_path = os.path.join(MP3_DIR, item_text.replace("[MP3] ", "", 1))

    if not os.path.exists(file_path):
        messagebox.showerror("File Error", "File not found.")
        return
    try:
        if sys.platform.startswith("win"):
            os.startfile(file_path)
        elif sys.platform == "darwin":
            subprocess.Popen(["open", file_path])
        else:
            subprocess.Popen(["xdg-open", file_path])
    except Exception as e:
        messagebox.showerror("Error", f"Could not open the file:\n{e}")

def pause_media():
    global is_paused
    if HAS_PYGAME and pygame.mixer.music.get_busy():
        if not is_paused:
            pygame.mixer.music.pause()
            is_paused = True
            player_status_label.config(text="Paused")
        else:
            pygame.mixer.music.unpause()
            is_paused = False
            player_status_label.config(text="Playing...")

def stop_media():
    global is_paused
    if HAS_PYGAME:
        pygame.mixer.music.stop()
        is_paused = False
        player_status_label.config(text="Stopped")
        media_canvas.itemconfig(canvas_text, text="[ In-App Media Screen ]")

# ==============================================================================
# GLASS ENGINE  (pure NumPy / Pillow, no window needed)
# ==============================================================================
# <<GLASS-ENGINE>>

BACKDROP_DOTS = False       # set True for an ultra-faint dot grid behind the glass
ROW_H = 46
C_TEXT, C_SUB, C_DIM = "#f2f2f2", "#8c8c8c", "#555555"

if sys.platform == "darwin":
    FONT = ".AppleSystemUIFont"
elif sys.platform.startswith("win"):
    FONT = "Segoe UI"
else:
    FONT = "Helvetica"
CURSOR = "pointinghand" if sys.platform == "darwin" else "hand2"


def _hex(c):
    return "#%02x%02x%02x" % tuple(int(max(0, min(255, v))) for v in c)


def _rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def _mix(a, b, t):
    a, b = _rgb(a), _rgb(b)
    return _hex([a[i] + (b[i] - a[i]) * t for i in range(3)])


def _clamp(v, a=0.0, b=1.0):
    return max(a, min(b, v))


def _ease(t):
    return 1 - (1 - t) ** 3


def _safe(s):
    """Tk on some Windows/Mac builds can't draw emoji (non-BMP characters)."""
    return "".join(ch for ch in str(s) if ord(ch) <= 0xFFFF)


def make_backdrop(w, h):
    """True black, with an optional ultra-faint dot grid so the glass has something to refract."""
    img = np.zeros((h, w, 3), np.float32)
    if BACKDROP_DOTS:
        sp = 28
        ys, xs = np.mgrid[0:sp, 0:sp].astype(np.float32)
        tile = np.clip(1.6 - np.hypot(xs - sp / 2, ys - sp / 2), 0, 1) * 20
        img += np.tile(tile, (h // sp + 1, w // sp + 1))[:h, :w, None]
    return img


def bilinear(src, X, Y):
    h, w = src.shape
    X = np.clip(X, 0, w - 1.001)
    Y = np.clip(Y, 0, h - 1.001)
    x0 = X.astype(np.int32)
    y0 = Y.astype(np.int32)
    fx = X - x0
    fy = Y - y0
    return ((src[y0, x0] * (1 - fx) + src[y0, x0 + 1] * fx) * (1 - fy)
            + (src[y0 + 1, x0] * (1 - fx) + src[y0 + 1, x0 + 1] * fx) * fy)


def glass_sprite(src, x0, y0, w, h, radius, bezel=14, strength=7.0, tint=0.06,
                 tint_col=(255, 255, 255), rim=1.0, glow=1.0, m=3, disp=(0.94, 1.0, 1.07)):
    """
    Clear glass: the rim gently bends what is behind it (a convex-lens profile with a
    touch of chromatic dispersion), over a barely-there fill, a hairline edge that
    catches light from the top-left, and a soft inner glow.  Returns (RGBA, ox, oy).
    """
    w, h = int(w), int(h)
    bezel = max(2.0, min(bezel, min(w, h) / 2.0 - 1))
    SW, SH = w + 2 * m, h + 2 * m
    ys, xs = np.mgrid[0:SH, 0:SW].astype(np.float32)
    px = xs + 0.5 - (m + w / 2.0)
    py = ys + 0.5 - (m + h / 2.0)
    qx = np.abs(px) - (w / 2.0 - radius)
    qy = np.abs(py) - (h / 2.0 - radius)
    sdf = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - radius
    gy, gx = np.gradient(sdf)
    nrm = np.hypot(gx, gy) + 1e-6
    nx, ny = gx / nrm, gy / nrm                      # outward normal
    mask = np.clip(0.5 - sdf, 0, 1)
    depth = np.maximum(-sdf, 0)
    tt = np.clip(depth / bezel, 0, 1)
    amt = 1 - np.sqrt(1 - (1 - tt) ** 2)             # lens profile: bends most at the edge

    gxp = xs + (x0 - m)
    gyp = ys + (y0 - m)
    k = strength * amt
    col = np.stack([bilinear(src[..., c], gxp + nx * k * disp[c], gyp + ny * k * disp[c])
                    for c in range(3)], -1)

    vg = np.clip(1 - (ys - m) / float(h), 0, 1)
    lift = (tint * (0.75 + 0.5 * vg))[..., None]
    col = col * (1 - lift) + np.array(tint_col, np.float32) * lift

    ndl = nx * -0.55 + ny * -0.83                    # light from the top-left
    pos = np.clip(ndl, 0, 1)
    neg = np.clip(-ndl, 0, 1)
    edge = np.exp(-(depth / 0.8) ** 2)               # ~1px hairline
    rim_a = rim * (0.16 + 0.55 * pos ** 1.3 + 0.28 * neg ** 1.6)
    inner = np.exp(-depth / 6.0) * (0.035 + 0.09 * pos + 0.03 * neg) * glow
    col = np.clip(col + 255 * (edge * rim_a + inner)[..., None], 0, 255)
    return np.dstack([col, mask]).astype(np.float32), int(x0 - m), int(y0 - m)


def bake(dst, spr, ox, oy):
    h, w = spr.shape[:2]
    X0, Y0 = max(ox, 0), max(oy, 0)
    X1, Y1 = min(ox + w, dst.shape[1]), min(oy + h, dst.shape[0])
    if X1 <= X0 or Y1 <= Y0:
        return
    s = spr[Y0 - oy:Y1 - oy, X0 - ox:X1 - ox]
    a = s[..., 3:4]
    dst[Y0:Y1, X0:X1] = dst[Y0:Y1, X0:X1] * (1 - a) + s[..., :3] * a


def put(scene, box, radius, **kw):
    """Bake a glass shape permanently into the scene image."""
    spr, ox, oy = glass_sprite(scene, *box, radius, **kw)
    bake(scene, spr, ox, oy)


def outline(scene, box, radius, line=46, fill=9):
    """Flat minimal surface: a near-black fill with a 1px hairline edge."""
    x, y, w, h = [int(v) for v in box]
    outer = rounded_mask(w, h, radius)[..., None]
    inner = np.pad(rounded_mask(w - 2, h - 2, max(1, radius - 1)), 1)[..., None]
    ring = np.clip(outer - inner, 0, 1)
    reg = scene[y:y + h, x:x + w]
    reg[:] = reg * (1 - outer) + fill * outer
    reg[:] = reg * (1 - ring) + line * ring


def to_photo(spr, amul=1.0):
    a = np.clip(spr[..., 3] * amul * 255, 0, 255)
    arr = np.dstack([np.clip(spr[..., :3], 0, 255), a]).astype(np.uint8)
    return ImageTk.PhotoImage(Image.fromarray(arr))


def rounded_mask(w, h, r, ss=4):
    w, h = int(w), int(h)
    im = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(im).rounded_rectangle((0, 0, w * ss - 1, h * ss - 1), radius=r * ss, fill=255)
    return np.asarray(im.resize((w, h), Image.LANCZOS), np.float32) / 255.0


def tinted_frames(mask, color, max_a, n=7):
    rgb = np.empty(mask.shape + (3,), np.float32)
    rgb[:] = color
    out = []
    for i in range(n):
        a = mask * max_a * i / (n - 1)
        out.append(ImageTk.PhotoImage(Image.fromarray(np.dstack([rgb, a * 255]).astype(np.uint8))))
    return out


def compute_layout(w, h):
    """All positions as a function of the window size (content is a centred column)."""
    cw = int(min(w - 80, 880))              # content column, capped so it stays centred when fullscreen
    ch = int(min(h - 64, 840))              # ...and capped in height so it centres vertically too
    x0 = (w - cw) // 2
    x1 = x0 + cw
    oy = max(24, (h - ch) // 2)
    return {
        "w": w, "h": h, "cw": cw, "x0": x0, "x1": x1,
        "title": (x0, oy + 14),
        "entry": (x0, oy + 52, cw, 48),
        "fmt": (x0, oy + 116, 260, 44),
        "dl": (x1 - 160, oy + 116, 160, 44),
        "openf": (x1 - 160 - 12 - 140, oy + 116, 140, 44),
        "paste": (x1 - 96, oy + 60, 88, 32),
        "status": (x0 + 4, oy + 176),
        "bar_y": oy + 198,
        "lib_title": (x0, oy + 231),
        "count": (x0 + 84, oy + 232),
        "filt": (x1 - 180, oy + 214, 180, 34),
        "newf": (x1 - 180 - 12 - 112, oy + 214, 112, 34),
        "search": (x0, oy + 260, cw, 42),
        "vy0": oy + 318,
        "vy1": oy + ch - 24,
    }


def render_scene(w, h, L):
    """Black background with every static glass control baked in."""
    scene = make_backdrop(w, h)
    outline(scene, L["entry"], 24)
    outline(scene, L["fmt"], 22)
    outline(scene, L["filt"], 17)
    outline(scene, L["dl"], 22, line=236, fill=236)          # solid white primary button
    outline(scene, L["newf"], 17)
    outline(scene, L["openf"], 22)
    outline(scene, L["paste"], 16, line=58, fill=24)
    outline(scene, L["search"], 21)
    return scene
# <<END-GLASS-ENGINE>>

# ==============================================================================
# APPLICATION WINDOW
# ==============================================================================

PANEL_BG = "#000000"
W, H = 900, 760
SCENE = None
L = None
_refs = []                  # keeps PhotoImages alive

root = tk.Tk()
root.title("Savetube")
root.configure(bg="#000000")
root.minsize(640, 640)
root.update_idletasks()
_sw, _sh = root.winfo_screenwidth(), root.winfo_screenheight()
_gw, _gh = min(W, _sw - 80), min(H, _sh - 120)
root.geometry(f"{_gw}x{_gh}+{max(0, (_sw - _gw) // 2)}+{max(0, (_sh - _gh) // 2 - 20)}")
try:
    root.attributes("-alpha", 0.0)
except tk.TclError:
    pass

canvas = tk.Canvas(root, bd=0, highlightthickness=0, bg="#000000")
canvas.pack(fill="both", expand=True)

F_ROW = tkfont.Font(family=FONT, size=13)
F_ROW_B = tkfont.Font(family=FONT, size=13, weight="bold")

# ---- animation engine --------------------------------------------------------

class Animator:
    def __init__(self):
        self.tweens, self.hooks, self.keep_hooks = [], [], []
        self.running, self.last = False, 0.0

    def reset(self):
        """Drop per-build widgets' tweens/hooks, keep the persistent ones."""
        self.tweens = [t for t in self.tweens if t.keep]
        self.hooks = list(self.keep_hooks)

    def wake(self):
        if not self.running:
            self.running = True
            self.last = time.time()
            root.after(12, self.step)

    def step(self):
        now = time.time()
        dt = min(now - self.last, 0.05)
        self.last = now
        busy = moved = False
        for tw in list(self.tweens):
            if tw.v == tw.t:
                continue
            if tw.lin:
                d = tw.lin * dt
                tw.v = tw.t if abs(tw.t - tw.v) <= d else tw.v + math.copysign(d, tw.t - tw.v)
            else:
                tw.v += (tw.t - tw.v) * (1 - math.exp(-tw.rate * dt))
                if abs(tw.t - tw.v) < tw.eps:
                    tw.v = tw.t
            moved = True
            if tw.cb:
                tw.cb(tw.v)
            if tw.v != tw.t:
                busy = True
        if moved:
            for h in list(self.hooks):
                h()
        if busy:
            root.after(12, self.step)
        else:
            self.running = False


ANIM = Animator()


class Tween:
    """A value that glides toward a target (exponential ease, or linear if lin is set)."""
    def __init__(self, v=0.0, rate=14.0, lin=None, eps=0.002, cb=None, keep=False):
        self.v = self.t = float(v)
        self.rate, self.lin, self.eps, self.cb, self.keep = rate, lin, eps, cb, keep
        ANIM.tweens.append(self)

    def go(self, t):
        self.t = float(t)
        if self.v != self.t:
            ANIM.wake()

    def snap(self, v):
        self.v = self.t = float(v)
        if self.cb:
            self.cb(self.v)


HITS, MODAL_HITS = [], []
toggle_var = tk.StringVar(value="All")


class Choice:
    """Holds the chosen download format (stand-in for the old Combobox: .get())."""
    def __init__(self, value):
        self.value = value

    def get(self):
        return self.value


format_combobox = Choice("MP4")


# ---- stand-ins for the old widgets, so the original logic is untouched ---------
class CanvasText:
    """Stand-in for a ttk.Label: supports .config(text=...)."""
    def __init__(self, text=""):
        self.text, self.item = text, None

    def attach(self, item):
        self.item = item
        canvas.itemconfigure(item, text=self.text)

    def _apply(self):
        if self.item is not None:
            canvas.itemconfigure(self.item, text=self.text)

    def config(self, **kw):
        if kw.get("text") is not None:
            self.text = _safe(kw["text"])
            root.after(0, self._apply)

    configure = config


class MediaScreen:
    """Stand-in for the old black Canvas: supports .itemconfig(item, text=...)."""
    def __init__(self):
        self.text, self.size, self.item = "[ In-App Media Screen ]", 12, None
        self.fade = Tween(1, rate=9, eps=0.01, keep=True, cb=self._fade)

    def _fade(self, v):
        if self.item is not None:
            canvas.itemconfigure(self.item, fill=_mix(C_DIM, C_TEXT, v))

    def attach(self, item):
        self.item = item
        canvas.itemconfigure(item, text=self.text, font=(FONT, self.size))
        self._fade(self.fade.v)

    def itemconfig(self, _item, **kw):
        t = kw.get("text")
        if t is None:
            return
        lines = [ln.strip() for ln in _safe(t).split("\n")]
        lines = [(ln if len(ln) <= 60 else ln[:57] + "…") for ln in lines if ln]
        self.text = "\n".join(lines[:3])
        self.size = 11 if len(lines) > 1 else 12

        def apply():
            if self.item is not None:
                canvas.itemconfigure(self.item, text=self.text, font=(FONT, self.size))
            self.fade.snap(0)
            self.fade.go(1)
        root.after(0, apply)


status_label = CanvasText("")
player_status_label = CanvasText("Ready")
media_canvas = MediaScreen()
canvas_text = None

# ==============================================================================
# LIBRARY  (smooth list + virtual folders)
# ==============================================================================

LIB_FILE = os.path.join(BASE_DIR, ".library.json")


def _fit(text, font, maxw):
    if font.measure(text) <= maxw:
        return text
    while text and font.measure(text + "…") > maxw:
        text = text[:-1]
    return text + "…"


class Library:
    def __init__(self):
        self.data = {"folders": [], "assign": {}}
        self._load()
        self.expanded, self.rows = {}, []
        self.sel_key = None
        self.press = self.drag = None
        self.last_toggle = 0.0
        self.content_h = 0
        self._last = None
        self._bar_job = None
        self.X0 = self.X1 = self.VY0 = self.VY1 = 0
        self.count_item, self.query = None, ""

        k = dict(keep=True)
        self.scroll = Tween(0, rate=14, eps=0.12, **k)
        self.morph = Tween(1, rate=13, **k)
        self.enter = Tween(9, lin=1.0, **k)
        self.sel_y = Tween(0, rate=16, eps=0.12, **k)
        self.sel_lvl = Tween(0, rate=14, eps=0.02, **k)
        self.hov_y = Tween(0, rate=22, eps=0.12, **k)
        self.hov_lvl = Tween(0, rate=16, eps=0.02, **k)
        self.bar = Tween(0, rate=6, eps=0.02, cb=self._bar_color, **k)
        ANIM.keep_hooks.append(self.layout)
        ANIM.hooks.append(self.layout)

    # ---- (re)create the visuals for the current window size ----------------
    def build(self, scene, Lo):
        self.X0, self.X1, self.VY0, self.VY1 = Lo["x0"], Lo["x1"], Lo["vy0"], Lo["vy1"]
        self.press = self.drag = None
        self._last = None
        pw, ph = self.X1 - self.X0 - 8, ROW_H - 8
        spr, _, _ = glass_sprite(scene, self.X0 + 4, self.VY0 + ROW_H, pw, ph, ph / 2,
                                 bezel=12, strength=5, tint=0.07, rim=0.5, glow=0.0)
        self.sel_frames = [to_photo(spr, i / 6) for i in range(7)]
        self.hov_frames = tinted_frames(rounded_mask(pw, ph, ph / 2), (255, 255, 255), 0.05)
        cx = (self.X0 + self.X1) / 2
        self.hov_img = canvas.create_image(cx, 0, image=self.hov_frames[0], state="hidden")
        self.sel_img = canvas.create_image(cx, 0, image=self.sel_frames[0], state="hidden")

        # soft fade strips that clip the list at the top and bottom
        self.strips = []
        sx0, sx1 = max(0, self.X0 - 16), min(Lo["w"], self.X1 + 24)
        fade = 18
        top_y0, bot_y1 = self.VY0 - ROW_H, self.VY1 + ROW_H
        a_top = np.concatenate([np.ones(ROW_H), np.linspace(1, 0, fade, endpoint=False)])
        a_bot = a_top[::-1]
        for (y0, y1, ramp) in ((top_y0, self.VY0 + fade, a_top), (self.VY1 - fade, bot_y1, a_bot)):
            crop = scene[y0:y1, sx0:sx1]
            alpha = np.repeat(ramp[:, None], crop.shape[1], 1)
            arr = np.dstack([crop, alpha * 255]).astype(np.uint8)
            img = ImageTk.PhotoImage(Image.fromarray(arr))
            self.strips.append(img)
            canvas.create_image(sx0, y0, anchor="nw", image=img, tags=("strip",))

        self.empty = canvas.create_text(cx, (self.VY0 + self.VY1) / 2, text="Nothing here yet.",
                                        fill=C_DIM, font=(FONT, 12), state="hidden")
        self.bar_item = canvas.create_line(self.X1 + 10, 0, self.X1 + 10, 0, width=3, capstyle="round",
                                           fill=PANEL_BG, state="hidden")

    # ---- persistence -------------------------------------------------------
    def _load(self):
        try:
            with open(LIB_FILE, "r", encoding="utf-8") as f:
                d = json.load(f)
            self.data["folders"] = [str(x) for x in d.get("folders", [])]
            self.data["assign"] = {str(k): str(v) for k, v in d.get("assign", {}).items()}
        except Exception:
            pass

    def _save(self):
        try:
            with open(LIB_FILE, "w", encoding="utf-8") as f:
                json.dump(self.data, f, indent=2, ensure_ascii=False)
        except Exception as e:
            print(f"Could not save library: {e}")

    # ---- shim methods used by play_selected_file ---------------------------
    def curselection(self):
        i = self._sel_index()
        return (i,) if i is not None and self.rows[i]["type"] == "file" else ()

    def get(self, i):
        return self.rows[i]["text"]

    # ---- building rows -----------------------------------------------------
    def _scan(self):
        out = []
        if os.path.exists(MP4_DIR):
            out += [("MP4", f) for f in os.listdir(MP4_DIR) if f.endswith(".mp4")]
        if os.path.exists(MP3_DIR):
            out += [("MP3", f) for f in os.listdir(MP3_DIR) if f.endswith(".mp3")]
        return sorted(out, key=lambda t: t[1].lower())

    def refresh(self, mode="fresh"):
        """mode: 'fresh' (staggered fade-in), 'morph' (rows glide), 'static' (no animation)."""
        everything = self._scan()
        present = {f"[{k}] {f}" for k, f in everything}
        stale = [k for k in self.data["assign"] if k not in present or self.data["assign"][k] not in self.data["folders"]]
        if stale:
            for k in stale:
                self.data["assign"].pop(k, None)
            self._save()

        flt = toggle_var.get()
        q = search_entry.get().strip().lower()
        self.query = q
        files = [(k, f) for k, f in everything
                 if flt in ("All", k) and q in os.path.splitext(f)[0].lower()]
        by_folder = {fo: [] for fo in self.data["folders"]}
        loose = []
        for kind, f in files:
            key = f"[{kind}] {f}"
            fo = self.data["assign"].get(key)
            (by_folder[fo] if fo in by_folder else loose).append((kind, f, key))

        items = []
        for fo in sorted(self.data["folders"], key=str.lower):
            if q and not by_folder[fo]:
                continue                                 # while searching, hide folders with no matches
            items.append({"type": "folder", "key": ("f", fo), "name": fo, "text": fo,
                          "count": len(by_folder[fo]), "indent": 0, "parent": None})
            if self.expanded.get(fo, True) or q:
                for kind, f, key in by_folder[fo]:
                    items.append({"type": "file", "key": ("m", key), "name": os.path.splitext(f)[0], "text": key,
                                  "kind": kind, "indent": 22, "parent": ("f", fo)})
        for kind, f, key in loose:
            items.append({"type": "file", "key": ("m", key), "name": os.path.splitext(f)[0], "text": key,
                          "kind": kind, "indent": 0, "parent": None})

        old = {r["key"]: r["cy"] for r in self.rows}
        canvas.delete("row")
        self.rows = []
        for i, it in enumerate(items):
            to = i * ROW_H
            if mode == "morph":
                frm = old.get(it["key"], old.get(it["parent"], to) if it["parent"] else to)
            else:
                frm = to
            maxw = self.X1 - self.X0 - 40 - it["indent"] - 70
            if it["type"] == "folder":
                shape = "tri_d" if (self.expanded.get(it["name"], True) or q) else "tri_r"
                icol, ncol, bcol = "#ffffff", "#ffffff", C_SUB
                name = _fit(_safe(it["name"]), F_ROW_B, maxw)
                badge = str(it["count"])
                nfont = (FONT, 13, "bold")
                sid = canvas.create_polygon(0, 0, 0, 0, 0, 0, fill=PANEL_BG, outline="", state="hidden", tags=("row",))
            else:
                shape = "dot"
                icol = "#d8d8d8" if it["kind"] == "MP3" else "#777777"
                ncol, bcol = "#e6e6e6", "#6a6a6a"
                name = _fit(_safe(it["name"]), F_ROW, maxw)
                badge = it["kind"]
                nfont = (FONT, 13)
                sid = canvas.create_oval(0, 0, 0, 0, fill=PANEL_BG, outline="", state="hidden", tags=("row",))
            ids = [
                sid,
                canvas.create_text(0, 0, text=name, anchor="w", font=nfont, fill=PANEL_BG, state="hidden", tags=("row",)),
                canvas.create_text(0, 0, text=badge, anchor="e", font=(FONT, 10, "bold"), fill=PANEL_BG, state="hidden", tags=("row",)),
            ]
            for i_ in ids:
                canvas.tag_lower(i_, "strip")
            it.update({"from": frm, "to": to, "cy": frm, "a": -1.0, "vis": False, "ids": ids,
                       "cols": [icol, ncol, bcol], "shape": shape})
            self.rows.append(it)

        self.content_h = len(self.rows) * ROW_H
        n = sum(1 for r in self.rows if r["type"] == "file")
        try:
            canvas.itemconfigure(self.empty, state="normal" if not self.rows else "hidden",
                                 text="No matches." if q else "Nothing here yet.")
            if self.count_item is not None:
                canvas.itemconfigure(self.count_item, text=f"{n} {'result' if q else 'item'}{'' if n == 1 else 's'}")
        except tk.TclError:
            pass
        self.scroll.t = self.scroll.v = _clamp(self.scroll.t, 0, self._max_scroll())

        if mode == "morph":
            self.morph.snap(0)
            self.morph.go(1)
        elif mode == "static":
            self.morph.snap(1)
            self.enter.snap(9)
        else:
            self.morph.snap(1)
            self.enter.snap(0)
            self.enter.go(0.48 + 0.4)
        si = self._sel_index()
        if si is None:
            self.sel_key = None
            self.sel_lvl.snap(0)
        else:
            if mode != "morph":
                self.sel_y.snap(self.rows[si]["to"])
            self.sel_y.go(self.rows[si]["to"])
        self.layout(force=True)

    def _max_scroll(self):
        return max(0, self.content_h - (self.VY1 - self.VY0))

    def _sel_index(self):
        for i, r in enumerate(self.rows):
            if r["key"] == self.sel_key:
                return i
        return None

    # ---- frame layout (runs every animation frame) --------------------------
    def layout(self, force=False):
        key = tuple(round(v, 3) for v in (self.scroll.v, self.morph.v, self.enter.v, self.sel_y.v,
                                          self.sel_lvl.v, self.hov_y.v, self.hov_lvl.v, self.bar.v))
        if key == self._last and not force:
            return
        self._last = key
        s, mo, en = self.scroll.v, self.morph.v, self.enter.v
        lo, hi = self.VY0 - ROW_H, self.VY1 + ROW_H
        for i, r in enumerate(self.rows):
            cy = r["from"] + (r["to"] - r["from"]) * mo
            r["cy"] = cy
            a = _ease(_clamp((en - min(i, 12) * 0.04) / 0.35))
            y = self.VY0 + cy - s + ROW_H / 2 + (1 - a) * 10
            vis = lo < y < hi and a > 0.0
            if vis != r["vis"]:
                st = "normal" if vis else "hidden"
                for i_ in r["ids"]:
                    canvas.itemconfigure(i_, state=st)
                r["vis"] = vis
            if not vis:
                continue
            ind = r["indent"]
            sx = self.X0 + 16 + ind
            if r["shape"] == "dot":
                canvas.coords(r["ids"][0], sx - 3, y - 3, sx + 3, y + 3)
            elif r["shape"] == "tri_d":
                canvas.coords(r["ids"][0], sx - 5, y - 3, sx + 5, y - 3, sx, y + 4)
            else:
                canvas.coords(r["ids"][0], sx - 3, y - 5, sx - 3, y + 5, sx + 4, y)
            canvas.coords(r["ids"][1], self.X0 + 40 + ind, y)
            canvas.coords(r["ids"][2], self.X1 - 12, y)
            if abs(a - r["a"]) > 1e-3:
                for i_, c in zip(r["ids"], r["cols"]):
                    canvas.itemconfigure(i_, fill=_mix(PANEL_BG, c, a))
                r["a"] = a

        cx = (self.X0 + self.X1) / 2
        sy = self.VY0 + self.sel_y.v - s + ROW_H / 2
        show = self._sel_index() is not None and self.sel_lvl.v > 0.02 and lo + 20 < sy < hi - 20
        canvas.itemconfigure(self.sel_img, state="normal" if show else "hidden",
                             image=self.sel_frames[int(round(_clamp(self.sel_lvl.v) * 6))])
        if show:
            canvas.coords(self.sel_img, cx, sy)
        hy = self.VY0 + self.hov_y.v - s + ROW_H / 2
        showh = self.hov_lvl.v > 0.02 and lo + 20 < hy < hi - 20
        canvas.itemconfigure(self.hov_img, state="normal" if showh else "hidden",
                             image=self.hov_frames[int(round(_clamp(self.hov_lvl.v) * 6))])
        if showh:
            canvas.coords(self.hov_img, cx, hy)

        ms = self._max_scroll()
        if ms > 0:
            vp = self.VY1 - self.VY0 - 16
            th = max(30, vp * vp / (vp + ms))
            top = self.VY0 + 8 + (s / ms) * (vp - th)
            canvas.coords(self.bar_item, self.X1 + 10, top, self.X1 + 10, top + th)
            canvas.itemconfigure(self.bar_item, state="normal" if self.bar.v > 0.02 else "hidden")
        else:
            canvas.itemconfigure(self.bar_item, state="hidden")

    def _bar_color(self, v):
        try:
            canvas.itemconfigure(self.bar_item, fill=_mix(PANEL_BG, "#bdbdbd", v))
        except (tk.TclError, AttributeError):
            pass

    # ---- geometry / hit testing -------------------------------------------
    def row_at(self, x, y):
        if not (self.X0 <= x <= self.X1 and self.VY0 <= y <= self.VY1):
            return None
        yc = y - self.VY0 + self.scroll.v
        for i, r in enumerate(self.rows):
            if r["cy"] <= yc < r["cy"] + ROW_H:
                return i
        return None

    # ---- interaction -------------------------------------------------------
    def wheel(self, e):
        if MODAL.active:
            return
        if not (self.X0 - 30 <= e.x <= self.X1 + 30 and self.VY0 - 24 <= e.y <= self.VY1 + 24):
            return
        if getattr(e, "num", 0) == 4:
            step = -70
        elif getattr(e, "num", 0) == 5:
            step = 70
        elif sys.platform == "darwin":
            step = -e.delta * 3.2
        else:
            step = -e.delta / 120.0 * 70
        self.scroll.go(_clamp(self.scroll.t + step, 0, self._max_scroll()))
        self.bar.go(1)
        if self._bar_job:
            root.after_cancel(self._bar_job)
        self._bar_job = root.after(900, lambda: self.bar.go(0))

    def move_sel(self, d):
        """Keyboard: select the previous/next song and scroll it into view."""
        idx = [i for i, r in enumerate(self.rows) if r["type"] == "file"]
        if not idx:
            return
        cur = self._sel_index()
        if cur in idx:
            j = _clamp(idx.index(cur) + d, 0, len(idx) - 1)
        else:
            j = 0 if d > 0 else len(idx) - 1
        i = idx[int(j)]
        self.select(i)
        top, vh = self.rows[i]["to"], self.VY1 - self.VY0
        if top < self.scroll.t:
            self.scroll.go(_clamp(top, 0, self._max_scroll()))
        elif top + ROW_H > self.scroll.t + vh:
            self.scroll.go(_clamp(top + ROW_H - vh, 0, self._max_scroll()))
        self.bar.go(1)
        if self._bar_job:
            root.after_cancel(self._bar_job)
        self._bar_job = root.after(900, lambda: self.bar.go(0))

    def show_in_folder(self, text):
        p = os.path.normpath(os.path.join(MP4_DIR if text.startswith("[MP4]") else MP3_DIR,
                                          text.split("] ", 1)[1]))
        try:
            if sys.platform.startswith("win"):
                subprocess.Popen(["explorer", "/select,", p])
            elif sys.platform == "darwin":
                subprocess.Popen(["open", "-R", p])
            else:
                subprocess.Popen(["xdg-open", os.path.dirname(p)])
        except Exception as e:
            messagebox.showerror("Error", f"Could not open the folder:\n{e}")

    def delete_file(self, text):
        p = os.path.join(MP4_DIR if text.startswith("[MP4]") else MP3_DIR, text.split("] ", 1)[1])
        if not messagebox.askyesno("Delete file", f"Delete '{os.path.basename(p)}' from your computer?\nThis can't be undone."):
            return
        try:
            os.remove(p)
        except Exception as e:
            messagebox.showerror("Error", f"Could not delete the file:\n{e}")
            return
        self.data["assign"].pop(text, None)
        self._save()
        if self.sel_key == ("m", text):
            self.sel_key = None
        self.refresh("morph")

    def select(self, i):
        r = self.rows[i]
        self.sel_key = r["key"]
        if self.sel_lvl.v < 0.05:
            self.sel_y.snap(r["cy"])
        self.sel_lvl.go(1)
        self.sel_y.go(r["to"])

    def motion(self, x, y):
        if self.drag:
            return
        self._hover(self.row_at(x, y))

    def _hover(self, i):
        if i is None:
            self.hov_lvl.go(0)
            return
        if self.hov_lvl.v < 0.05:
            self.hov_y.snap(self.rows[i]["cy"])
        self.hov_y.go(self.rows[i]["to"])
        self.hov_lvl.go(1)

    def press_(self, e):
        i = self.row_at(e.x, e.y)
        if i is None:
            self.press = None
            return
        self.press = (e.x, e.y, i)
        if self.rows[i]["type"] == "file":
            self.select(i)

    def drag_motion(self, x, y):
        if not self.press:
            return
        px, py, i = self.press
        if i >= len(self.rows):
            return
        if not self.drag and math.hypot(x - px, y - py) > 8 and self.rows[i]["type"] == "file":
            self.drag = canvas.create_text(x + 14, y, anchor="w", text=_safe(self.rows[i]["name"]),
                                           fill=C_TEXT, font=(FONT, 12, "bold"))
            canvas.tag_raise(self.drag)
        if self.drag:
            canvas.coords(self.drag, x + 14, y)
            self._hover(self.row_at(x, y))
            if y < self.VY0 + 14:
                self.scroll.go(_clamp(self.scroll.t - 46, 0, self._max_scroll()))
            elif y > self.VY1 - 14:
                self.scroll.go(_clamp(self.scroll.t + 46, 0, self._max_scroll()))

    def release(self, x, y):
        if not self.press:
            return
        px, py, i = self.press
        self.press = None
        if self.drag:
            canvas.delete(self.drag)
            self.drag = None
            self.hov_lvl.go(0)
            j = self.row_at(x, y)
            if j is None or i >= len(self.rows):
                return
            tgt = self.rows[j]
            target = tgt["name"] if tgt["type"] == "folder" else self.data["assign"].get(tgt["text"])
            src = self.rows[i]["text"]
            if self.data["assign"].get(src) != target:
                self.assign(src, target)
            return
        if i < len(self.rows) and self.rows[i]["type"] == "folder" and time.time() - self.last_toggle > 0.3:
            self.last_toggle = time.time()
            fo = self.rows[i]["name"]
            self.expanded[fo] = not self.expanded.get(fo, True)
            self.refresh("morph")

    # ---- folder operations -------------------------------------------------
    def assign(self, text, folder):
        if folder is None:
            self.data["assign"].pop(text, None)
        else:
            self.data["assign"][text] = folder
            self.expanded[folder] = True
        self._save()
        self.refresh("morph")

    def new_folder(self, name, then_assign=None):
        name = name.strip()
        if not name or name in self.data["folders"]:
            return
        self.data["folders"].append(name)
        self.expanded[name] = True
        if then_assign:
            self.data["assign"][then_assign] = name
        self._save()
        self.refresh("morph")

    def rename(self, old, new):
        new = new.strip()
        if not new or new == old or new in self.data["folders"]:
            return
        self.data["folders"] = [new if f == old else f for f in self.data["folders"]]
        for k, v in list(self.data["assign"].items()):
            if v == old:
                self.data["assign"][k] = new
        self.expanded[new] = self.expanded.pop(old, True)
        self._save()
        self.refresh("morph")

    def delete_folder(self, name):
        if not messagebox.askyesno("Delete folder", f"Delete the folder '{name}'?\nThe files inside are kept."):
            return
        self.data["folders"] = [f for f in self.data["folders"] if f != name]
        for k, v in list(self.data["assign"].items()):
            if v == name:
                del self.data["assign"][k]
        self._save()
        self.refresh("morph")

    def context(self, e):
        if MODAL.active:
            return
        i = self.row_at(e.x, e.y)
        if i is None:
            return
        r = self.rows[i]
        m = tk.Menu(root, tearoff=0)
        if r["type"] == "file":
            self.select(i)
            m.add_command(label="Open", command=open_selected_file)
            m.add_command(label="Show in Folder", command=lambda t=r["text"]: self.show_in_folder(t))
            m.add_separator()
            sub = tk.Menu(m, tearoff=0)
            folders = sorted(self.data["folders"], key=str.lower)
            for fo in folders:
                sub.add_command(label=fo, command=lambda fo=fo, t=r["text"]: self.assign(t, fo))
            if folders:
                sub.add_separator()
            sub.add_command(label="New Folder…", command=lambda t=r["text"]: MODAL.open(
                "New folder", "", lambda n, t=t: self.new_folder(n, t)))
            m.add_cascade(label="Move to Folder", menu=sub)
            if r["text"] in self.data["assign"]:
                m.add_command(label="Remove from Folder", command=lambda t=r["text"]: self.assign(t, None))
            m.add_separator()
            m.add_command(label="Delete File…", command=lambda t=r["text"]: self.delete_file(t))
        else:
            fo = r["name"]
            m.add_command(label="Rename Folder…", command=lambda: MODAL.open(
                "Rename folder", fo, lambda n: self.rename(fo, n)))
            m.add_command(label="Delete Folder", command=lambda: self.delete_folder(fo))
        try:
            m.tk_popup(e.x_root, e.y_root)
        finally:
            m.grab_release()


# ==============================================================================
# WIDGETS
# ==============================================================================

class GlassButton:
    """Glass pill/circle with a text label or a drawn icon (identical on Windows and Mac)."""
    def __init__(self, box, text, command, size=12, hits=None, visible=True, icon=None, solid=False):
        self.box, self.command, self.vis = box, command, visible
        x, y, w, h = box
        if solid:   # white button: hover/press darkens it slightly
            self.frames = tinted_frames(rounded_mask(w, h, h / 2), (0, 0, 0), 0.14)
        else:       # outlined button: hover/press lifts it with a soft white wash
            self.frames = tinted_frames(rounded_mask(w, h, h / 2), (255, 255, 255), 0.09)
        self.img = canvas.create_image(x, y, anchor="nw", image=self.frames[0], state="hidden")
        cx, cy = x + w / 2, y + h / 2
        fg = "#000000" if solid else C_TEXT
        if icon == "play":
            self.fg = [canvas.create_polygon(cx - 4, cy - 8, cx - 4, cy + 8, cx + 8, cy, fill=fg, outline="")]
        elif icon == "pause":
            self.fg = [canvas.create_rectangle(cx - 6, cy - 7, cx - 2, cy + 7, fill=fg, outline=""),
                       canvas.create_rectangle(cx + 2, cy - 7, cx + 6, cy + 7, fill=fg, outline="")]
        elif icon == "stop":
            self.fg = [canvas.create_rectangle(cx - 6, cy - 6, cx + 6, cy + 6, fill=fg, outline="")]
        else:
            self.fg = [canvas.create_text(cx, cy, text=text, fill=fg, font=(FONT, size, "bold"))]
        self._off = 0.0
        self.lvl = Tween(0, rate=18, eps=0.03, cb=self._lvl)
        self.prs = Tween(0, rate=34, eps=0.03, cb=self._prs)
        self.set_visible(visible)
        (HITS if hits is None else hits).append(self)

    def items(self):
        return [self.img] + self.fg

    def set_visible(self, v):
        self.vis = v
        for i in self.fg:
            canvas.itemconfigure(i, state="normal" if v else "hidden")
        self._lvl(self.lvl.v)

    def _lvl(self, v):
        i = int(round(_clamp(v) * 6))
        canvas.itemconfigure(self.img, image=self.frames[i], state="normal" if (i and self.vis) else "hidden")

    def _prs(self, v):
        d = v * 1.5
        for i in self.fg:
            canvas.move(i, 0, d - self._off)
        self._off = d

    def enter(self):
        self.lvl.go(0.5)

    def leave(self):
        self.lvl.go(0)
        self.prs.go(0)

    def down(self, x=0, y=0):
        self.prs.go(1)
        self.lvl.go(1.0)

    def up(self, inside):
        self.prs.go(0)
        self.lvl.go(0.5 if inside else 0)
        if inside and self.command:
            self.command()


class Segmented:
    """Glass segmented control with a sliding glass thumb."""
    def __init__(self, scene, box, options, value, on_change=None, size=11):
        x, y, w, h = box
        self.box, self.opts, self.value, self.cb = box, options, value, on_change
        n = len(options)
        self.cw, self.x0, self.y0, self.m = (w - 8) / n, x + 4, y + 4, 3
        ch = h - 8
        spr, _, _ = glass_sprite(scene, int(self.x0), int(self.y0), int(self.cw), int(ch), ch / 2,
                                 bezel=11, strength=5, tint=0.10, rim=0.55, glow=0.0, m=self.m)
        self.photo = to_photo(spr)
        self.pos = Tween(options.index(value), rate=17, eps=0.003)
        self.thumb = canvas.create_image(0, 0, anchor="nw", image=self.photo)
        self.labels = [canvas.create_text(x + 4 + self.cw * (k + 0.5), y + h / 2, text=o,
                                          font=(FONT, size, "bold"), fill=C_DIM)
                       for k, o in enumerate(options)]
        ANIM.hooks.append(self._render)
        self._render()
        HITS.append(self)

    def _render(self):
        p = self.pos.v
        canvas.coords(self.thumb, self.x0 + p * self.cw - self.m, self.y0 - self.m)
        for k, l in enumerate(self.labels):
            canvas.itemconfigure(l, fill=_mix(C_DIM, C_TEXT, _clamp(1 - abs(p - k))))

    def enter(self):
        pass

    def leave(self):
        pass

    def down(self, x=0, y=0):
        i = int(_clamp((x - self.x0) // self.cw, 0, len(self.opts) - 1))
        if self.opts[i] != self.value:
            self.value = self.opts[i]
            self.pos.go(i)
            if self.cb:
                self.cb(self.value)

    def up(self, inside):
        pass


class GlassEntry(tk.Entry):
    PH = "Paste a video link"

    def __init__(self, master, ph=None, **kw):
        super().__init__(master, **kw)
        if ph:
            self.PH = ph
        self._ph = False
        self._show_ph()
        self.bind("<FocusIn>", self._in, add="+")
        self.bind("<FocusOut>", self._out, add="+")

    def get(self):
        return "" if self._ph else super().get()

    def set_text(self, text):
        tk.Entry.delete(self, 0, "end")
        tk.Entry.insert(self, 0, text)
        self.config(fg=C_TEXT)
        self._ph = False

    def _show_ph(self):
        tk.Entry.delete(self, 0, "end")
        tk.Entry.insert(self, 0, self.PH)
        self.config(fg=C_DIM)
        self._ph = True

    def _in(self, e=None):
        if self._ph:
            tk.Entry.delete(self, 0, "end")
            self.config(fg=C_TEXT)
            self._ph = False

    def _out(self, e=None):
        if not super().get():
            self._show_ph()


url_entry = GlassEntry(root, bd=0, highlightthickness=0, relief="flat", bg="#0a0a0a", fg=C_TEXT,
                       insertbackground=C_TEXT, font=(FONT, 13), selectbackground="#555555")
search_entry = GlassEntry(root, ph="Search your library", bd=0, highlightthickness=0, relief="flat",
                          bg="#090909", fg=C_TEXT, insertbackground=C_TEXT, font=(FONT, 12),
                          selectbackground="#555555")
search_clear = None


class ClearBtn:
    """Little x at the end of the search field (only active while there is a query)."""
    def __init__(self, box, command):
        self.box, self.command, self.enabled = box, command, False
        x, y, w, h = box
        cx, cy = x + w / 2, y + h / 2
        self.items = [canvas.create_line(cx - 4, cy - 4, cx + 4, cy + 4, fill=C_SUB, width=2, capstyle="round", state="hidden"),
                      canvas.create_line(cx - 4, cy + 4, cx + 4, cy - 4, fill=C_SUB, width=2, capstyle="round", state="hidden")]
        self.hv = Tween(0, rate=18, eps=0.03, cb=self._hv)
        HITS.append(self)

    def set_enabled(self, on):
        self.enabled = bool(on)
        for i in self.items:
            canvas.itemconfigure(i, state="normal" if on else "hidden")

    def _hv(self, v):
        for i in self.items:
            canvas.itemconfigure(i, fill=_mix(C_SUB, C_TEXT, v))

    def enter(self):
        self.hv.go(1)

    def leave(self):
        self.hv.go(0)

    def down(self, x=0, y=0):
        pass

    def up(self, inside):
        if inside and self.enabled:
            self.command()


class ProgressBar:
    """Thin progress line under the download row: fills while downloading, sweeps while converting."""
    def __init__(self, x0, x1, y, ty):
        self.x0, self.x1, self.y, self.dead, self._ticking = x0, x1, y, False, False
        self.track = canvas.create_line(x0 + 2, y, x1 - 2, y, width=4, capstyle="round", fill=PANEL_BG)
        self.fill = canvas.create_line(x0 + 2, y, x0 + 2, y, width=4, capstyle="round",
                                       fill=PANEL_BG, state="hidden")
        self.pct = canvas.create_text(x1, ty, anchor="e", text="", fill=PANEL_BG, font=(FONT, 10, "bold"))
        self.val = Tween(PROG["value"], rate=10, eps=0.001, cb=self._render)
        self.vis = Tween(0, rate=9, eps=0.01, cb=self._render)
        self.sync()

    def sync(self):
        mode = PROG["mode"]
        self.vis.go(1 if mode in ("progress", "busy", "done") else 0)
        self.val.go(PROG["value"])
        if mode == "busy" and not self._ticking:
            self._ticking = True
            self._tick()
        self._render()

    def _tick(self):
        if self.dead or PROG["mode"] != "busy":
            self._ticking = False
            if not self.dead:
                self._render()
            return
        self._render()
        root.after(30, self._tick)

    def _render(self, _v=None):
        a = _clamp(self.vis.v)
        canvas.itemconfigure(self.track, fill=_mix(PANEL_BG, "#222222", a))
        canvas.itemconfigure(self.pct, fill=_mix(PANEL_BG, C_SUB, a))
        span = self.x1 - self.x0 - 4
        if PROG["mode"] == "busy":
            seg = 110
            s = ((time.time() % 1.3) / 1.3) * (span + seg) - seg
            sx, ex = max(0.0, s), min(float(span), s + seg)
            canvas.itemconfigure(self.pct, text="")
        else:
            sx, ex = 0.0, span * _clamp(self.val.v)
            canvas.itemconfigure(self.pct, text=f"{int(round(_clamp(self.val.v) * 100))}%" if a > 0.02 else "")
        if ex - sx >= 1:
            canvas.coords(self.fill, self.x0 + 2 + sx, self.y, self.x0 + 2 + ex, self.y)
            canvas.itemconfigure(self.fill, state="normal", fill=_mix(PANEL_BG, "#ffffff", a))
        else:
            canvas.itemconfigure(self.fill, state="hidden")


class Toast:
    """Small white pill that fades in with a check mark ("Download success") and fades out again."""
    def __init__(self, cx, cy):
        w, h = 236, 42
        self.cx, self.cy, self.job = cx, cy, None
        self.frames = tinted_frames(rounded_mask(w, h, h / 2), (236, 236, 236), 1.0)
        self.img = canvas.create_image(cx - w / 2, cy - h / 2, anchor="nw", image=self.frames[0], state="hidden")
        self.txt = canvas.create_text(cx + 12, cy, text="", fill="#000000", font=(FONT, 11, "bold"), state="hidden")
        self.i1 = canvas.create_line(0, 0, 0, 0, fill="#000000", width=2.4, capstyle="round", joinstyle="round", state="hidden")
        self.i2 = canvas.create_line(0, 0, 0, 0, fill="#000000", width=2.4, capstyle="round", state="hidden")
        self.lvl = Tween(0, rate=14, eps=0.03, cb=self._lvl)
        self.ok = True

    def _lvl(self, v):
        i = int(round(_clamp(v) * 6))
        canvas.itemconfigure(self.img, image=self.frames[i], state="normal" if i else "hidden")
        st = "normal" if v > 0.6 else "hidden"
        canvas.itemconfigure(self.txt, state=st)
        canvas.itemconfigure(self.i1, state=st)
        canvas.itemconfigure(self.i2, state=st if not self.ok else "hidden")

    def show(self, text, ok=True):
        self.ok = ok
        ix, cy = self.cx - 118 + 26, self.cy
        canvas.itemconfigure(self.txt, text=text)
        if ok:
            canvas.coords(self.i1, ix - 6, cy, ix - 2, cy + 4, ix + 6, cy - 5)
        else:
            canvas.coords(self.i1, ix - 4, cy - 4, ix + 4, cy + 4)
            canvas.coords(self.i2, ix - 4, cy + 4, ix + 4, cy - 4)
        for i in (self.img, self.txt, self.i1, self.i2):
            canvas.tag_raise(i)
        self.lvl.go(1)
        if self.job:
            root.after_cancel(self.job)
        self.job = root.after(3800, lambda: self.lvl.go(0))


PBAR = None
TOAST = None


def progress_update(fn, frac, exp, speed, eta):
    P = PROG
    if fn and fn not in P["seen"]:
        P["seen"].append(fn)
    idx = P["seen"].index(fn) if fn in P["seen"] else 0
    exp = max(exp, len(P["seen"]), 1)
    inner = (min(idx, exp - 1) + _clamp(frac)) / exp
    overall = (P["stage"] + inner) / P["stages"]
    P["value"] = max(P["value"], min(overall, 0.99))        # never goes backwards
    P["mode"] = "progress"
    bits = [f"Downloading {P['fmt']}"]
    if speed:
        bits.append(f"{speed / 1048576:.1f} MB/s")
    if eta is not None:
        bits.append(f"{int(eta) // 60}:{int(eta) % 60:02d} left")
    status_label.config(text="  ·  ".join(bits))
    if PBAR:
        PBAR.sync()


def progress_busy(text):
    PROG["mode"] = "busy"
    status_label.config(text=text)
    if PBAR:
        PBAR.sync()


def progress_begin(n, stages, fmt):
    PROG.update(stage=n, stages=stages, seen=[], fmt=fmt, mode="busy")
    PROG["value"] = n / stages
    if PBAR:
        if n == 0:
            PBAR.val.snap(0)
        PBAR.sync()


def _clear_done():
    if PROG["mode"] == "done":
        PROG["mode"] = "idle"
        if PBAR:
            PBAR.sync()


def _clear_status():
    if status_label.text == "Download success" and PROG["mode"] == "idle":
        status_label.config(text="")


def progress_finish(ok):
    if ok:
        PROG.update(mode="done", value=1.0)
        status_label.config(text="Download success")
        if TOAST:
            TOAST.show("Download success", True)
        root.after(2200, _clear_done)
        root.after(7000, _clear_status)
    else:
        PROG.update(mode="idle", value=0.0)
        if TOAST:
            TOAST.show("Download failed", False)
    if PBAR:
        PBAR.sync()


def paste_from_clipboard(e=None):
    """Put the clipboard text into the link field (works the same on Windows and Mac)."""
    try:
        txt = root.clipboard_get()
    except tk.TclError:
        txt = ""
    lines = (txt or "").strip().splitlines()
    if not lines:
        status_label.config(text="Clipboard is empty.")
        return
    url_entry.set_text(lines[0].strip())
    status_label.config(text="Link pasted.")


def _open_path(p):
    try:
        if sys.platform.startswith("win"):
            os.startfile(p)
        elif sys.platform == "darwin":
            subprocess.Popen(["open", p])
        else:
            subprocess.Popen(["xdg-open", p])
    except Exception as e:
        messagebox.showerror("Error", f"Could not open the folder:\n{e}")


def open_download_folder():
    """Opens the folder for the selected format (asks which one when 'Both' is selected)."""
    fmt = format_combobox.get()
    if fmt == "MP4":
        _open_path(MP4_DIR)
    elif fmt == "MP3":
        _open_path(MP3_DIR)
    else:
        m = tk.Menu(root, tearoff=0)
        m.add_command(label="Open MP4 folder", command=lambda: _open_path(MP4_DIR))
        m.add_command(label="Open MP3 folder", command=lambda: _open_path(MP3_DIR))
        try:
            m.tk_popup(root.winfo_pointerx(), root.winfo_pointery())
        finally:
            m.grab_release()


class Modal:
    """Small glass dialog for naming folders (centred, rebuilt whenever the window is resized)."""
    def __init__(self):
        self.active, self.built, self.cb, self.entry = False, False, None, None
        self.fade = Tween(0, rate=16, eps=0.02, keep=True, cb=self._fade)

    def reset(self):
        self.active, self.built = False, False
        if self.entry is not None:
            try:
                self.entry.destroy()
            except tk.TclError:
                pass
            self.entry = None

    def _build(self):
        cw_, ch_ = 400, 210
        cx0, cy0 = (W - cw_) // 2, (H - ch_) // 2
        self.card = (cx0, cy0, cw_, ch_)
        self.field = (cx0 + 32, cy0 + 72, cw_ - 64, 44)
        self.b_cancel_box = (cx0 + 32, cy0 + 140, 160, 44)
        self.b_ok_box = (cx0 + cw_ - 32 - 160, cy0 + 140, 160, 44)
        s = SCENE.copy()
        outline(s, self.card, 28, line=52, fill=12)
        outline(s, self.field, 22, line=46, fill=0)
        outline(s, self.b_cancel_box, 22)
        outline(s, self.b_ok_box, 22, line=236, fill=236)
        self.frames = []
        crop = s[cy0 - 3:cy0 + ch_ + 3, cx0 - 3:cx0 + cw_ + 3]
        for i in range(5):
            arr = np.dstack([crop, np.full(crop.shape[:2], 255.0 * i / 4)]).astype(np.uint8)
            self.frames.append(ImageTk.PhotoImage(Image.fromarray(arr)))
        self.img = canvas.create_image(cx0 - 3, cy0 - 3, anchor="nw", image=self.frames[0], state="hidden")
        self.title = canvas.create_text(cx0 + cw_ / 2, cy0 + 38, text="", fill=C_TEXT,
                                        font=(FONT, 15, "bold"), state="hidden")
        fx, fy, fw, fh = self.field
        self.entry = tk.Entry(root, bd=0, highlightthickness=0, relief="flat",
                              bg=_hex(s[fy + fh // 2, fx + fw // 2]), fg=C_TEXT, insertbackground=C_TEXT,
                              font=(FONT, 13), selectbackground="#555555")
        self.win = canvas.create_window(fx + 20, fy + 9, anchor="nw", window=self.entry,
                                        width=fw - 40, height=26, state="hidden")
        self.b_cancel = GlassButton(self.b_cancel_box, "Cancel", self.close, hits=MODAL_HITS, visible=False)
        self.b_ok = GlassButton(self.b_ok_box, "Save", self.submit, hits=MODAL_HITS, visible=False, solid=True)
        self.entry.bind("<Return>", lambda e: (self.submit(), "break")[1])
        self.entry.bind("<Escape>", lambda e: (self.close(), "break")[1])
        self.built = True

    def open(self, title, initial, cb):
        if SCENE is None:
            return
        if not self.built:
            self._build()
        self.active, self.cb = True, cb
        canvas.itemconfigure(self.img, state="normal")
        canvas.tag_raise(self.img)
        canvas.itemconfigure(self.title, text=title, state="normal")
        canvas.tag_raise(self.title)
        canvas.itemconfigure(url_win, state="hidden")
        self.entry.delete(0, "end")
        self.entry.insert(0, initial)
        canvas.itemconfigure(self.win, state="normal")
        for b in (self.b_cancel, self.b_ok):
            b.set_visible(True)
            for i in b.items():
                canvas.tag_raise(i)
        self.fade.go(1)
        self.entry.focus_force()
        self.entry.select_range(0, "end")

    def submit(self):
        name = self.entry.get().strip()
        cb = self.cb
        self.close()
        if name and cb:
            cb(name)

    def close(self):
        if not self.active:
            return
        self.active = False
        canvas.itemconfigure(self.title, state="hidden")
        canvas.itemconfigure(self.win, state="hidden")
        for b in (self.b_cancel, self.b_ok):
            b.set_visible(False)
            b.lvl.snap(0)
        canvas.itemconfigure(url_win, state="normal")
        canvas.focus_set()
        self.fade.go(0)

    def _fade(self, v):
        if not self.built:
            return
        i = int(round(_clamp(v) * 4))
        canvas.itemconfigure(self.img, image=self.frames[i], state="normal" if (i or self.active) else "hidden")


MODAL = Modal()
file_listbox = Library()
url_win = None


def refresh_file_list():
    root.after(0, lambda: file_listbox.refresh("fresh"))


# ==============================================================================
# BUILD / REBUILD THE INTERFACE  (runs at start and whenever the window is resized)
# ==============================================================================

_state = {"hover": None, "down": None}


def _filter_changed(v):
    toggle_var.set(v)
    refresh_file_list()


def _set_format(v):
    format_combobox.value = v


def _search_changed(e=None):
    if search_clear is not None:
        search_clear.set_enabled(bool(search_entry.get()))
    file_listbox.scroll.snap(0)
    file_listbox.refresh("morph")


def clear_search():
    tk.Entry.delete(search_entry, 0, "end")
    search_entry._ph = False
    try:
        focused = root.focus_get() is search_entry
    except KeyError:
        focused = False
    if not focused:
        search_entry._show_ph()
    _search_changed()


def build():
    global W, H, SCENE, L, url_win, _refs, search_clear, PBAR, TOAST
    w, h = canvas.winfo_width(), canvas.winfo_height()
    if w < 300 or h < 300:
        return
    if PBAR is not None:
        PBAR.dead = True
    W, H = w, h
    MODAL.reset()
    ANIM.reset()
    HITS.clear()
    MODAL_HITS.clear()
    _state["hover"] = _state["down"] = None
    canvas.delete("all")
    L = compute_layout(W, H)
    SCENE = render_scene(W, H, L)
    base = ImageTk.PhotoImage(Image.fromarray(np.clip(SCENE, 0, 255).astype(np.uint8)))
    _refs = [base]
    canvas.create_image(0, 0, anchor="nw", image=base)

    file_listbox.build(SCENE, L)                       # list first so everything else sits above its fade strips

    canvas.create_text(*L["title"], anchor="w", text="Savetube", fill=C_TEXT, font=(FONT, 24, "bold"))

    ex, ey, ew, eh = L["entry"]
    url_entry.config(bg=_hex(SCENE[ey + eh // 2, ex + ew // 2]))
    url_win = canvas.create_window(ex + 24, ey + 11, anchor="nw", window=url_entry, width=ew - 48 - 100, height=26)
    GlassButton(L["paste"], "Paste", paste_from_clipboard, size=10)
    ring_frames = tinted_frames(
        np.clip(rounded_mask(ew, eh, eh / 2) - np.pad(rounded_mask(ew - 4, eh - 4, eh / 2 - 2), 2), 0, 1),
        (255, 255, 255), 0.55)
    _refs.append(ring_frames)
    ring = canvas.create_image(ex, ey, anchor="nw", image=ring_frames[0], state="hidden")
    ring_t = Tween(0, rate=14, eps=0.03, cb=lambda v: canvas.itemconfigure(
        ring, image=ring_frames[int(round(_clamp(v) * 6))], state="normal" if v > 0.02 else "hidden"))
    url_entry.bind("<FocusIn>", lambda e: ring_t.go(1), add="")
    url_entry.bind("<FocusOut>", lambda e: ring_t.go(0), add="")
    url_entry._ph_bind()                                # re-attach placeholder handlers after rebind
    if url_entry.focus_get() is url_entry:
        ring_t.snap(1)

    Segmented(SCENE, L["fmt"], ["MP4", "MP3", "Both"], format_combobox.value, _set_format)
    GlassButton(L["dl"], "Download", process_download, size=12, solid=True)
    GlassButton(L["openf"], "Open Folder", open_download_folder, size=11)
    status_label.attach(canvas.create_text(*L["status"], anchor="w", text="", fill=C_SUB, font=(FONT, 10)))

    canvas.create_text(*L["lib_title"], anchor="w", text="Library", fill=C_TEXT, font=(FONT, 14, "bold"))
    GlassButton(L["newf"], "+  Folder", lambda: MODAL.open("New folder", "", file_listbox.new_folder), size=10)
    Segmented(SCENE, L["filt"], ["All", "MP4", "MP3"], toggle_var.get(), _filter_changed, size=10)
    file_listbox.count_item = canvas.create_text(*L["count"], anchor="w", text="", fill=C_DIM, font=(FONT, 10))

    # search field: magnifier, entry, clear button
    sx, sy, sw, sh = L["search"]
    mx, my = sx + 22, sy + sh / 2
    canvas.create_oval(mx - 6, my - 7, mx + 4, my + 3, outline=C_SUB, width=2)
    canvas.create_line(mx + 3, my + 2, mx + 8, my + 7, fill=C_SUB, width=2, capstyle="round")
    search_entry.config(bg=_hex(SCENE[sy + sh // 2, sx + sw // 2]))
    canvas.create_window(sx + 42, sy + (sh - 26) // 2, anchor="nw", window=search_entry,
                         width=sw - 42 - 44, height=26)
    search_clear = ClearBtn((sx + sw - 40, sy + 4, 34, sh - 8), clear_search)
    search_clear.set_enabled(bool(search_entry.get()))

    PBAR = ProgressBar(L["x0"], L["x1"], L["bar_y"], L["status"][1])
    TOAST = Toast(W // 2, L["vy1"] - 26)

    file_listbox.refresh("static")


# placeholder handlers must survive the rebinding of FocusIn/Out above
def _ph_bind(self):
    self.bind("<FocusIn>", self._in, add="+")
    self.bind("<FocusOut>", self._out, add="+")


GlassEntry._ph_bind = _ph_bind

# ==============================================================================
# EVENT ROUTING
# ==============================================================================

def _hit_at(x, y):
    for o in (MODAL_HITS if MODAL.active else HITS):
        if not getattr(o, "enabled", True):
            continue
        bx, by, bw, bh = o.box
        if bx <= x <= bx + bw and by <= y <= by + bh:
            return o
    return None


def _on_motion(e):
    o = _hit_at(e.x, e.y)
    if o is not _state["hover"]:
        if _state["hover"]:
            _state["hover"].leave()
        _state["hover"] = o
        if o:
            o.enter()
        canvas.config(cursor=CURSOR if o else "")
    if not MODAL.active:
        file_listbox.motion(e.x, e.y)


def _on_press(e):
    if MODAL.active:
        o = _hit_at(e.x, e.y)
        if o:
            _state["down"] = o
            o.down(e.x, e.y)
        return
    canvas.focus_set()
    o = _hit_at(e.x, e.y)
    if o:
        _state["down"] = o
        o.down(e.x, e.y)
    else:
        file_listbox.press_(e)


def _on_release(e):
    o = _state["down"]
    if o:
        _state["down"] = None
        bx, by, bw, bh = o.box
        o.up(bx <= e.x <= bx + bw and by <= e.y <= by + bh)
    elif not MODAL.active:
        file_listbox.release(e.x, e.y)


def _on_drag(e):
    if not MODAL.active and not _state["down"]:
        file_listbox.drag_motion(e.x, e.y)


def _on_double(e):
    _on_press(e)
    if MODAL.active:
        return
    i = file_listbox.row_at(e.x, e.y)
    if i is not None and file_listbox.rows[i]["type"] == "file":
        open_selected_file()


# ---- resizing + fullscreen ---------------------------------------------------
_resize = {"job": None, "size": (0, 0)}


def _on_configure(e):
    if (e.width, e.height) == _resize["size"]:
        return
    _resize["size"] = (e.width, e.height)
    if _resize["job"]:
        root.after_cancel(_resize["job"])
    _resize["job"] = root.after(180, build)


def _toggle_fullscreen(e=None):
    try:
        root.attributes("-fullscreen", not bool(root.attributes("-fullscreen")))
    except tk.TclError:
        pass
    return "break"


def _exit_fullscreen(e=None):
    try:
        if root.attributes("-fullscreen"):
            root.attributes("-fullscreen", False)
    except tk.TclError:
        pass


canvas.bind("<Configure>", _on_configure)
canvas.bind("<Motion>", _on_motion)
canvas.bind("<ButtonPress-1>", _on_press)
canvas.bind("<ButtonRelease-1>", _on_release)
canvas.bind("<B1-Motion>", _on_drag)
canvas.bind("<Double-Button-1>", _on_double)
canvas.bind("<MouseWheel>", file_listbox.wheel)       # Windows + macOS
canvas.bind("<Button-4>", file_listbox.wheel)         # Linux
canvas.bind("<Button-5>", file_listbox.wheel)
# right-click: Button-3 on Windows/Linux, Button-2 on macOS, Ctrl-click on Mac trackpads
for _seq in ("<Button-2>", "<Button-3>", "<Control-Button-1>"):
    canvas.bind(_seq, file_listbox.context)
root.bind("<F11>", _toggle_fullscreen)
root.bind("<Alt-Return>", _toggle_fullscreen)
root.bind("<Escape>", _exit_fullscreen)


# ---- keyboard: search, download, and moving through the list ------------------
def _typing():
    try:
        return root.focus_get() in (url_entry, search_entry, MODAL.entry)
    except KeyError:
        return True


def _focus_search(e=None):
    search_entry.focus_set()
    return "break"


def _on_up(e):
    if MODAL.active or _typing():
        return
    file_listbox.move_sel(-1)
    return "break"


def _on_down(e):
    if MODAL.active or _typing():
        return
    file_listbox.move_sel(1)
    return "break"


def _on_return(e):
    if MODAL.active or _typing():
        return
    open_selected_file()


def _search_escape(e):
    clear_search()
    canvas.focus_set()
    return "break"


search_entry.bind("<KeyRelease>", _search_changed, add="+")
search_entry.bind("<Escape>", _search_escape)
url_entry.bind("<Return>", lambda e: process_download())
root.bind("<Up>", _on_up)
root.bind("<Down>", _on_down)
root.bind("<Return>", _on_return)
root.bind("<Control-f>" if sys.platform != "darwin" else "<Command-f>", _focus_search)


def _on_paste_key(e):
    """Ctrl/Cmd+V pastes the link into the link box when you are not already typing in a text box."""
    if MODAL.active or _typing():                      # inside a text box Tk pastes natively
        return
    paste_from_clipboard()
    return "break"


_mod = "Command" if sys.platform == "darwin" else "Control"
for _seq in (f"<{_mod}-v>", f"<{_mod}-V>"):
    try:
        root.bind(_seq, _on_paste_key)
    except tk.TclError:
        pass

# first build, then start the background script threads
root.update_idletasks()
build()
refresh_file_list()
start_background_scripts()

# gentle fade-in of the whole window
_intro = Tween(0, rate=7, eps=0.01, keep=True, cb=lambda v: root.attributes("-alpha", _clamp(v)))
root.after(60, lambda: _intro.go(1))

root.mainloop()
