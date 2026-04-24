// Design tokens — native macOS Sequoia vocabulary.
// Two themes: light + dark. Low-saturation, eye-friendly.
// Reference: System Settings, Xcode, native toolbars.

const lightTheme = {
  // Window chrome
  chromeBg: '#ECECEC',
  chromeBorder: 'rgba(0,0,0,0.10)',

  // Content canvases
  windowBg: '#F5F5F5',          // main content area behind cards
  cardBg: '#FFFFFF',
  cardBorder: 'rgba(0,0,0,0.06)',
  cardShadow: '0 0 0 0.5px rgba(0,0,0,0.06), 0 1px 2px rgba(0,0,0,0.04)',

  // Sidebar (vibrancy-ish)
  sidebarBg: '#E8E8E8',
  sidebarItemActive: 'rgba(0,0,0,0.08)',
  sidebarItemHover: 'rgba(0,0,0,0.04)',

  // Text
  textPrimary: 'rgba(0,0,0,0.88)',
  textSecondary: 'rgba(0,0,0,0.55)',
  textTertiary: 'rgba(0,0,0,0.38)',
  textOnAccent: '#FFFFFF',

  // Separators
  hairline: 'rgba(0,0,0,0.08)',
  hairlineStrong: 'rgba(0,0,0,0.14)',

  // Controls
  controlBg: '#FFFFFF',
  controlBgRest: '#FDFDFD',
  controlBorder: 'rgba(0,0,0,0.14)',
  controlShadow: '0 0.5px 0 rgba(0,0,0,0.04)',
  fieldBg: '#FFFFFF',
  fieldBorder: 'rgba(0,0,0,0.10)',

  // Accents
  accent: '#0064E0',            // refined system blue (lower chroma)
  accentHover: '#004FC2',
  accentBgSoft: 'rgba(0,100,224,0.08)',
  accentBorderSoft: 'rgba(0,100,224,0.18)',
  violet: '#6B48C9',             // Hyper key
  violetBgSoft: 'rgba(107,72,201,0.10)',
  green: '#2EA045',              // running dot
  greenSoft: 'rgba(46,160,69,0.10)',
  red: '#D13B3B',
  redBgSoft: 'rgba(209,59,59,0.08)',
  redBorderSoft: 'rgba(209,59,59,0.20)',
  amber: '#C77800',
  amberBgSoft: 'rgba(199,120,0,0.10)',

  // Misc
  heatmapBase: 'rgba(0,100,224,0.10)',
  focusRing: 'rgba(0,100,224,0.35)',
};

const darkTheme = {
  chromeBg: '#2C2C2E',
  chromeBorder: 'rgba(255,255,255,0.08)',

  // eye-friendly: not pure black; slight warm cast avoided, use very slight
  // blue-gray so text isn't harsh
  windowBg: '#1C1C1E',
  cardBg: '#232326',
  cardBorder: 'rgba(255,255,255,0.06)',
  cardShadow: '0 0 0 0.5px rgba(0,0,0,0.4), 0 1px 3px rgba(0,0,0,0.3)',

  sidebarBg: '#252527',
  sidebarItemActive: 'rgba(255,255,255,0.08)',
  sidebarItemHover: 'rgba(255,255,255,0.04)',

  textPrimary: 'rgba(255,255,255,0.92)',
  textSecondary: 'rgba(235,235,245,0.55)',
  textTertiary: 'rgba(235,235,245,0.32)',
  textOnAccent: '#FFFFFF',

  hairline: 'rgba(255,255,255,0.08)',
  hairlineStrong: 'rgba(255,255,255,0.14)',

  controlBg: '#3A3A3C',
  controlBgRest: '#2E2E30',
  controlBorder: 'rgba(255,255,255,0.10)',
  controlShadow: '0 0.5px 0 rgba(255,255,255,0.04)',
  fieldBg: '#2A2A2C',
  fieldBorder: 'rgba(255,255,255,0.08)',

  accent: '#2A8FFF',             // slightly softer than pure #0A84FF — easier on eyes
  accentHover: '#4AA0FF',
  accentBgSoft: 'rgba(42,143,255,0.16)',
  accentBorderSoft: 'rgba(42,143,255,0.28)',
  violet: '#A689F0',
  violetBgSoft: 'rgba(166,137,240,0.18)',
  green: '#40C060',
  greenSoft: 'rgba(64,192,96,0.16)',
  red: '#FF5F58',
  redBgSoft: 'rgba(255,95,88,0.12)',
  redBorderSoft: 'rgba(255,95,88,0.24)',
  amber: '#F5B53F',
  amberBgSoft: 'rgba(245,181,63,0.14)',

  heatmapBase: 'rgba(42,143,255,0.20)',
  focusRing: 'rgba(42,143,255,0.45)',
};

// App icon placeholders (solid rounded squares w/ letter) — we don't
// recreate the Zed/Safari/Notes/Terminal marks.
const appIconBg = {
  zed:      { l: '#2A2A2E', d: '#2A2A2E', glyph: '◬', glyphColor: '#ECECEC' },
  terminal: { l: '#1C1C1E', d: '#0A0A0C', glyph: '>_', glyphColor: '#D8D8D8' },
  safari:   { l: '#1C82E8', d: '#1876D0', glyph: '⌖', glyphColor: '#FFFFFF' },
  notes:    { l: '#F5C642', d: '#E0A918', glyph: '≡', glyphColor: '#7A5A10' },
  figma:    { l: '#F24E1E', d: '#F24E1E', glyph: 'F', glyphColor: '#FFFFFF' },
  slack:    { l: '#4A154B', d: '#4A154B', glyph: '#', glyphColor: '#ECB22E' },
  xcode:    { l: '#1475CF', d: '#1475CF', glyph: 'X', glyphColor: '#FFFFFF' },
  mail:     { l: '#3D9BFF', d: '#3D9BFF', glyph: '✉', glyphColor: '#FFFFFF' },
};

const SF = `-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro", "Helvetica Neue", Helvetica, Arial, sans-serif`;
const SFMono = `"SF Mono", ui-monospace, Menlo, Monaco, Consolas, monospace`;

Object.assign(window, { lightTheme, darkTheme, appIconBg, SF, SFMono });
