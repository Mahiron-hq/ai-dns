"""Renders an AI-DNS log as an animated GIF of the console window that produced it.

The log carries every console line with its timestamp and level, so the run can be replayed with its
real pacing. Lines that only went to the log (trace records, run headers, per-service details of
working resolvers) are left out, and details that identify the machine are replaced, so the result
can be published. Requires Pillow.
"""

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# Windows Terminal "Campbell", the default palette of the Windows 10 and 11 console host.
COLORS = {
    'Background': (12, 12, 12),
    'Gray': (204, 204, 204),
    'DarkGray': (118, 118, 118),
    'White': (242, 242, 242),
    'Green': (22, 198, 12),
    'Yellow': (249, 241, 165),
    'Red': (231, 72, 86),
    'Cyan': (97, 214, 214),
    'DarkCyan': (58, 150, 221),
    'DarkMagenta': (136, 23, 152),
    'Title': (32, 32, 32),
    'TitleText': (220, 220, 220),
}

LINE = re.compile(r'^(\d\d):(\d\d):(\d\d)\.(\d{3}) (\S+)\s+(.*)$')
ROW = re.compile(r'^(.{1,15}?) +\d{1,3}(?:\.\d{1,3}){3} ')

# Console lines that identify the machine or its other software. Russian and English wording,
# including the 3.0 phrasing, is listed because logs of any version can be replayed.
DROP = [
    re.compile(p) for p in (
        r'VPN-клиент', r'VPN client', r'виртуальный или VPN-адаптер', r'virtual or VPN adapter',
    )
]
LOG_ONLY = [
    re.compile(p) for p in (
        r'^AI-DNS \d+\.\d+\.\d+, Windows', r'^Options: ', r'^Services: ', r'^Exit code ', r'^Не отвечают: ',
        r'^Not answering: ', r'^Required service choice: ', r'^Unexpected pipeline output: ',
    )
]
# Per-service details of a resolver row; only failures of websites and Claude Code reach the console.
# Labels may contain a colon themselves ("Claude Code: sign-in"), so a working service is found by ": OK, ".
DETAIL_OK = re.compile(r': OK, ')
DETAIL_API = re.compile(r'^[^:]* API: ')


@dataclass
class Line:
    ms: int
    text: str
    color: str


def anonymize(text):
    text = re.sub(r'((?:текущие DNS|current DNS) ).*$', r'\g<1>192.168.1.1', text)
    text = re.sub(r'^((?:Лог|Log): ).*[\\/]([a-z]+_\d{8}_\d{6}\.log)$', r'\g<1>C:\\ProgramData\\AIDNS\\logs\\\g<2>', text)
    return text


def row_color(text):
    """Colors a resolver row the way Show-CandidateTable does: by how many websites it opens."""
    head = re.split(r'\s+Claude Code [+-]|\s+API \d', text, maxsplit=1)[0]
    marks = re.findall(r'\s([+-])(?=\s|$)', head)
    if marks and all(m == '+' for m in marks):
        return 'Green'
    if '+' in marks:
        return 'Yellow'
    return 'DarkGray'


def is_row(text):
    match = ROW.match(text)
    return match is not None and ': ' not in match.group(1)


def console_lines(path):
    lines = []
    # A resolver that opens no website shows only its last detail line, the summary of its failures.
    dead_row = []
    in_dead_row = False

    def flush_dead_row():
        if dead_row:
            lines.append(dead_row[-1])
            dead_row.clear()

    for raw in path.read_text(encoding='utf-8-sig').splitlines():
        match = LINE.match(raw)
        if not match:
            continue
        h, m, s, f, level, text = match.groups()
        ms = ((int(h) * 60 + int(m)) * 60 + int(s)) * 1000 + int(f)
        if lines and ms < lines[-1].ms:
            ms += 24 * 3600 * 1000
        if level in ('TRACE', 'DEBUG', 'ERROR') and not text.startswith('[x]'):
            continue
        if any(p.search(text) for p in DROP) or any(p.search(text) for p in LOG_ONLY):
            continue
        text = anonymize(text)
        if level != 'TEST' or is_row(text):
            flush_dead_row()
            in_dead_row = False

        if level == 'STEP':
            lines.append(Line(ms, '', 'Gray'))
            lines.append(Line(ms, text, 'Cyan'))
        elif level in ('OK', 'WARN', 'ERROR'):
            lines.append(Line(ms, '  ' + text, {'OK': 'Green', 'WARN': 'Yellow', 'ERROR': 'Red'}[level]))
        elif level == 'DRY':
            if not text.startswith('before:'):
                lines.append(Line(ms, '      ' + text, 'DarkMagenta'))
        elif level == 'TEST':
            if is_row(text):
                color = row_color(text)
                lines.append(Line(ms, '  ' + text, color))
                in_dead_row = color == 'DarkGray'
                continue
            if in_dead_row:
                dead_row.append(Line(ms, '      ' + text, 'DarkGray'))
                continue
            if DETAIL_OK.search(text) or DETAIL_API.match(text):
                continue
            lines.append(Line(ms, '      ' + text, 'DarkGray'))
        elif level == 'INFO':
            if not text:
                lines.append(Line(ms, '', 'Gray'))
            elif text[0] in '\u2554\u2551\u255a':
                lines.append(Line(ms, '  ' + text, 'DarkCyan'))
            else:
                lines.append(Line(ms, '      ' + text, 'DarkGray'))
    flush_dead_row()
    return lines


def group_frames(lines, speed, max_pause_ms, min_frame_ms):
    """Groups lines that appeared together and turns the gaps between groups into frame durations."""
    groups = []
    for line in lines:
        if groups and line.ms - groups[-1][0] < min_frame_ms:
            groups[-1][1].append(line)
        else:
            groups.append([line.ms, [line]])
    frames = []
    for index, (start, members) in enumerate(groups):
        end = groups[index + 1][0] if index + 1 < len(groups) else start
        pause = min(end - start, max_pause_ms) / speed
        frames.append((members, max(int(pause), min_frame_ms)))
    return frames


def load_font(size):
    for name in ('consola.ttf', 'C:/Windows/Fonts/consola.ttf', 'DejaVuSansMono.ttf', 'LiberationMono-Regular.ttf'):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    sys.exit('No monospace TrueType font found (Consolas or DejaVu Sans Mono).')


def render(frames, footer, title, columns, rows, font_size, hold_ms):
    font = load_font(font_size)
    cell_w = round(font.getlength('M'))
    ascent, descent = font.getmetrics()
    cell_h = ascent + descent
    pad = 12
    bar = cell_h + 14
    width = columns * cell_w + pad * 2
    height = bar + rows * cell_h + pad * 2

    def draw(screen):
        image = Image.new('RGB', (width, height), COLORS['Background'])
        canvas = ImageDraw.Draw(image)
        canvas.rectangle((0, 0, width, bar), fill=COLORS['Title'])
        canvas.text((pad, (bar - cell_h) // 2 + 1), title, font=font, fill=COLORS['TitleText'])
        # Minimize, maximize and close, drawn as shapes because console fonts lack these glyphs.
        mid, size, color = bar // 2, 5, COLORS['TitleText']
        close_x, max_x, min_x = width - 24, width - 70, width - 116
        canvas.line((min_x - size, mid, min_x + size, mid), fill=color)
        canvas.rectangle((max_x - size, mid - size, max_x + size, mid + size), outline=color)
        canvas.line((close_x - size, mid - size, close_x + size, mid + size), fill=color)
        canvas.line((close_x - size, mid + size, close_x + size, mid - size), fill=color)
        for row, line in enumerate(screen[-rows:]):
            text = line.text if len(line.text) <= columns else line.text[:columns - 1] + '\u2026'
            canvas.text((pad, bar + pad + row * cell_h), text, font=font, fill=COLORS[line.color])
        return image

    screen = []
    images, durations = [], []
    for members, duration in frames:
        screen.extend(members)
        images.append(draw(screen))
        durations.append(duration)
    if footer:
        screen.extend([Line(0, '', 'Gray'), Line(0, footer, 'DarkGray')])
        images.append(draw(screen))
        durations.append(hold_ms)
    elif durations:
        durations[-1] = hold_ms

    # One palette for every frame keeps colors stable and lets the encoder store only changed areas.
    palette = images[-1].quantize(colors=64, method=Image.Quantize.MEDIANCUT)
    quantized = [image.quantize(palette=palette, dither=Image.Dither.NONE) for image in images]
    return quantized, durations


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--log', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--title', default='Administrator: Windows PowerShell')
    parser.add_argument('--footer', default='')
    parser.add_argument('--columns', type=int, default=104)
    parser.add_argument('--rows', type=int, default=30)
    parser.add_argument('--font-size', type=int, default=15)
    parser.add_argument('--speed', type=float, default=1.5, help='replay speed relative to the real run')
    parser.add_argument('--max-pause', type=int, default=1400, help='longest pause between lines, in ms of the real run')
    parser.add_argument('--hold', type=int, default=5000, help='how long the last frame stays, in ms')
    args = parser.parse_args()

    lines = console_lines(args.log)
    if not lines:
        sys.exit(f'{args.log}: no console lines found; is this an AI-DNS log?')
    # GIF delays are whole centiseconds and browsers stretch anything under 20 ms, so frames are at least 60 ms.
    frames = group_frames(lines, args.speed, args.max_pause, 60)
    images, durations = render(frames, args.footer, args.title, args.columns, args.rows, args.font_size, args.hold)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    images[0].save(args.out, save_all=True, append_images=images[1:], duration=durations, loop=0, optimize=True, disposal=1)
    print(f'{args.out}: {len(images)} frames, {sum(durations) / 1000:.1f} s, {args.out.stat().st_size / 1024:.0f} KB')


if __name__ == '__main__':
    main()
