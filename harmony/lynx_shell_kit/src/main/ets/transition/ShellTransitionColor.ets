interface ShellRGBA { red: number; green: number; blue: number; alpha: number; }

/** wire使用#RRGGBBAA，与双端相同；Canvas统一收到rgba，避免平台8位hex顺序歧义。 */
export default class ShellTransitionColor {
  static parse(raw: string): ShellRGBA {
    const value = raw.trim().toLowerCase();
    const names: Record<string, string> = { black: '#000000', darkgray: '#444444', gray: '#888888', lightgray: '#cccccc', white: '#ffffff',
      red: '#ff0000', green: '#00ff00', blue: '#0000ff', yellow: '#ffff00', cyan: '#00ffff', magenta: '#ff00ff', transparent: '#00000000' };
    const normalized = names[value] ?? value;
    if (/^#[0-9a-f]{6}(?:[0-9a-f]{2})?$/.test(normalized)) return { red: parseInt(normalized.substring(1, 3), 16), green: parseInt(normalized.substring(3, 5), 16),
      blue: parseInt(normalized.substring(5, 7), 16), alpha: normalized.length === 9 ? parseInt(normalized.substring(7, 9), 16) / 255 : 1 };
    const match = /^(rgba?)\(([^)]+)\)$/.exec(normalized);
    if (match === null) throw new Error('transition_color_invalid');
    const parts = match[2].split(',').map((v) => v.trim());
    if (parts.length !== (match[1] === 'rgb' ? 3 : 4)) throw new Error('transition_color_invalid');
    const channel = (v: string, max: number): number => {
      if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?%?$/.test(v)) throw new Error('transition_color_invalid');
      const percent = v.endsWith('%'); const n = Number(percent ? v.substring(0, v.length - 1) : v);
      if (!Number.isFinite(n) || n < 0 || n > (percent ? 100 : max)) throw new Error('transition_color_invalid');
      return percent ? n * max / 100 : n;
    };
    return { red: Math.round(channel(parts[0], 255)), green: Math.round(channel(parts[1], 255)), blue: Math.round(channel(parts[2], 255)), alpha: parts.length === 4 ? Math.round(channel(parts[3], 1) * 255) / 255 : 1 };
  }
  static mix(from: string, to: string, progress: number): string {
    if (!Number.isFinite(progress)) throw new Error('transition_progress_invalid');
    const a = ShellTransitionColor.parse(from); const b = ShellTransitionColor.parse(to); const t = Math.max(0, Math.min(1, progress));
    return `rgba(${Math.round(a.red + (b.red - a.red) * t)},${Math.round(a.green + (b.green - a.green) * t)},${Math.round(a.blue + (b.blue - a.blue) * t)},${a.alpha + (b.alpha - a.alpha) * t})`;
  }
}
