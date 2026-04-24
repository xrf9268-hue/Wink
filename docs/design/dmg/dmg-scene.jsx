// DMG install scene primitives for Wink.
//
// Context: the user double-clicks Wink.dmg → macOS mounts the disk image
// and opens a Finder window showing its contents. DMG authors customize:
//   1. window background image (the "scene")
//   2. icon positions (app icon on left, /Applications symlink on right)
//   3. hidden toolbar / sidebar / status bar for a clean look
// The user drags the app onto the Applications folder to install.
//
// What we're designing: the *background image* plus the framing window so
// you can judge how it looks in situ. The traffic-light chrome and the
// two icons are rendered on top for review — in the actual .dmg only the
// background PNG is ours, the icons are Finder-rendered.
//
// Standard window size: 620x420 is Apple's most common DMG canvas;
// anything from 540x380 to 720x480 is fine. We use 640x400.

const DMG_W = 640;
const DMG_H = 400;

// Finder window chrome — traffic lights + blurred title bar, sidebar
// hidden (as DMG authors do via `bless`/DS_Store tricks).
function DMGWindow({ title = 'Wink', tone = 'light', children, bgNode }) {
  const isDark = tone === 'dark';
  return (
    <div style={{
      width: DMG_W, height: DMG_H + 44,
      borderRadius: 12, overflow: 'hidden',
      fontFamily: window.SF,
      background: isDark ? '#1C1C1E' : '#F5F5F5',
      boxShadow: isDark
        ? '0 0 0 0.5px rgba(255,255,255,0.08), 0 24px 60px rgba(0,0,0,0.55)'
        : '0 0 0 0.5px rgba(0,0,0,0.10), 0 24px 60px rgba(0,0,0,0.18)',
      display: 'flex', flexDirection: 'column',
    }}>
      {/* Title bar */}
      <div style={{
        height: 44, flexShrink: 0,
        background: isDark
          ? 'linear-gradient(180deg, #3A3A3C 0%, #2C2C2E 100%)'
          : 'linear-gradient(180deg, #F7F7F7 0%, #E8E8E8 100%)',
        borderBottom: `0.5px solid ${isDark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.12)'}`,
        display: 'flex', alignItems: 'center',
        position: 'relative',
      }}>
        <window.TrafficLights />
        <div style={{
          position: 'absolute', inset: 0,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          pointerEvents: 'none',
          color: isDark ? 'rgba(255,255,255,0.85)' : 'rgba(0,0,0,0.78)',
          fontSize: 13, fontWeight: 500, letterSpacing: 0.05,
        }}>
          {/* tiny mounted-disk icon to match Finder behavior */}
          <svg width="13" height="13" viewBox="0 0 16 16" style={{ marginRight: 6 }}>
            <rect x="1.5" y="3" width="13" height="10" rx="1.5" fill="none"
              stroke="currentColor" strokeWidth="1.1" opacity="0.55"/>
            <circle cx="4" cy="8" r="0.9" fill="currentColor" opacity="0.55"/>
          </svg>
          {title}
        </div>
      </div>
      {/* Scene */}
      <div style={{
        position: 'relative', width: DMG_W, height: DMG_H,
        overflow: 'hidden',
      }}>
        {bgNode}
        {children}
      </div>
    </div>
  );
}

// ------------------------------------------------------------------
// Icon renderers
// ------------------------------------------------------------------

// The Wink app icon as it sits in the DMG — big rounded-square tile.
// Mirrors the v2 dock-tile treatment (violet hero gradient + Twin mark).
function WinkAppIcon({ size = 112, palette = 'violet' }) {
  const bgs = {
    violet: 'linear-gradient(135deg, #8A5BE3 0%, #5E3FC7 60%, #4A7BE8 100%)',
    ink:    'linear-gradient(160deg, #2E2630 0%, #18141A 100%)',
    warm:   'linear-gradient(135deg, #E8945B 0%, #C46A2E 100%)',
    cream:  'linear-gradient(135deg, #F5F1E8 0%, #E6DFCF 100%)',
  };
  const isLight = palette === 'cream';
  // macOS icons sit in a 22.37% rounded square (superellipse-ish).
  const radius = size * 0.225;
  return (
    <div style={{
      width: size, height: size, borderRadius: radius,
      background: bgs[palette] || bgs.violet,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      color: isLight ? '#2A2021' : '#fff',
      boxShadow: `
        0 1px 0 rgba(255,255,255,0.12) inset,
        0 0 0 0.5px rgba(0,0,0,0.18),
        0 ${size * 0.09}px ${size * 0.18}px rgba(24,20,30,0.28),
        0 ${size * 0.02}px ${size * 0.04}px rgba(24,20,30,0.18)
      `,
      position: 'relative',
    }}>
      <window.Logo_WinkTwin size={size * 0.58} color="currentColor" />
      {/* subtle top-sheen */}
      <div style={{
        position: 'absolute', inset: 0, borderRadius: radius,
        background: 'linear-gradient(180deg, rgba(255,255,255,0.14) 0%, rgba(255,255,255,0) 35%)',
        pointerEvents: 'none',
      }}/>
    </div>
  );
}

// /Applications symlink — rendered as a stylized folder icon.
// Not the real Finder Applications icon (copyrighted), but a Finder-style
// folder silhouette with "Applications" label and the small A glyph.
function ApplicationsFolderIcon({ size = 112, tone = 'light' }) {
  const isDark = tone === 'dark';
  // Mac folder shape: a back tab + a front panel.
  const w = size;
  const h = size * 0.86;
  return (
    <div style={{
      width: w, height: size, position: 'relative',
      display: 'flex', alignItems: 'flex-end',
    }}>
      <svg width={w} height={h} viewBox="0 0 100 86" style={{ filter: 'drop-shadow(0 8px 14px rgba(24,20,30,0.25)) drop-shadow(0 1px 2px rgba(24,20,30,0.18))' }}>
        <defs>
          <linearGradient id={`folderBack-${tone}`} x1="0" x2="0" y1="0" y2="1">
            <stop offset="0" stopColor={isDark ? '#4A7FC9' : '#7DB4F0'}/>
            <stop offset="1" stopColor={isDark ? '#3A68B0' : '#5E98DE'}/>
          </linearGradient>
          <linearGradient id={`folderFront-${tone}`} x1="0" x2="0" y1="0" y2="1">
            <stop offset="0" stopColor={isDark ? '#6A9BDE' : '#9EC8F3'}/>
            <stop offset="1" stopColor={isDark ? '#4C7FBF' : '#6FA0DC'}/>
          </linearGradient>
        </defs>
        {/* back tab */}
        <path d="M4 10 Q4 6, 8 6 L38 6 L45 12 L92 12 Q96 12, 96 16 L96 30 L4 30 Z"
          fill={`url(#folderBack-${tone})`}/>
        {/* front panel */}
        <path d="M4 24 Q4 20, 8 20 L92 20 Q96 20, 96 24 L96 78 Q96 82, 92 82 L8 82 Q4 82, 4 78 Z"
          fill={`url(#folderFront-${tone})`}/>
        {/* inner highlight on front panel */}
        <path d="M7 22.5 L93 22.5" stroke="rgba(255,255,255,0.38)" strokeWidth="0.8"/>
        {/* the "A" glyph — hints at Applications */}
        <g transform="translate(50 56)" fill="rgba(255,255,255,0.85)">
          <path d="M -14 14 L 0 -16 L 14 14 L 8 14 L 5 7 L -5 7 L -8 14 Z M -3 2 L 3 2 L 0 -5 Z"/>
        </g>
      </svg>
    </div>
  );
}

// Label under each icon, Finder-style (11pt SF, shadow on dark bgs).
function IconLabel({ text, tone = 'light', onDark = false }) {
  const color = onDark
    ? 'rgba(255,255,255,0.95)'
    : (tone === 'dark' ? 'rgba(255,255,255,0.9)' : 'rgba(0,0,0,0.82)');
  return (
    <div style={{
      marginTop: 10, fontSize: 12, fontWeight: 500,
      color, textAlign: 'center',
      textShadow: onDark ? '0 1px 2px rgba(0,0,0,0.45)' : 'none',
      letterSpacing: 0.1,
    }}>{text}</div>
  );
}

// Arrow between the two icons — the visual instruction.
function DragArrow({ variant = 'solid', tone = 'light' }) {
  const dark = tone === 'dark';
  const stroke = dark ? 'rgba(255,255,255,0.65)' : 'rgba(0,0,0,0.55)';
  if (variant === 'dashed') {
    return (
      <svg width="150" height="34" viewBox="0 0 150 34" fill="none">
        <path d="M8 17 L132 17" stroke={stroke} strokeWidth="1.6"
          strokeLinecap="round" strokeDasharray="2 6"/>
        <path d="M132 10 L142 17 L132 24" stroke={stroke} strokeWidth="1.6"
          strokeLinecap="round" strokeLinejoin="round" fill="none"/>
      </svg>
    );
  }
  if (variant === 'chevrons') {
    return (
      <svg width="150" height="34" viewBox="0 0 150 34" fill="none">
        {[0, 1, 2, 3].map(i => (
          <path key={i}
            d={`M${24 + i * 28} 10 L${34 + i * 28} 17 L${24 + i * 28} 24`}
            stroke={stroke} strokeWidth="1.8"
            strokeLinecap="round" strokeLinejoin="round"
            opacity={0.3 + i * 0.22}/>
        ))}
      </svg>
    );
  }
  // solid arrow (default)
  return (
    <svg width="150" height="34" viewBox="0 0 150 34" fill="none">
      <path d="M6 17 L134 17" stroke={stroke} strokeWidth="1.8" strokeLinecap="round"/>
      <path d="M128 9 L140 17 L128 25" stroke={stroke} strokeWidth="1.8"
        strokeLinecap="round" strokeLinejoin="round" fill="none"/>
    </svg>
  );
}

Object.assign(window, {
  DMG_W, DMG_H,
  DMGWindow, WinkAppIcon, ApplicationsFolderIcon, IconLabel, DragArrow,
});
