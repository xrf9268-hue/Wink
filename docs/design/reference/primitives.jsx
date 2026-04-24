// Small reusable primitives used by all screens. All take a `t` theme obj.

// Traffic lights
function TrafficLights({ muted = false }) {
  const dots = muted
    ? ['#C8C8C8', '#C8C8C8', '#C8C8C8']
    : ['#FF5F57', '#FEBC2E', '#28C840'];
  return (
    <div style={{ display: 'flex', gap: 8, padding: '0 16px' }}>
      {dots.map((c, i) => (
        <div key={i} style={{
          width: 12, height: 12, borderRadius: '50%',
          background: c, boxShadow: 'inset 0 0 0 0.5px rgba(0,0,0,0.12)'
        }} />
      ))}
    </div>
  );
}

// App icon — solid rounded square w/ letter glyph placeholder
function AppIcon({ app = 'zed', size = 28, theme = 'light' }) {
  const spec = window.appIconBg[app] || window.appIconBg.zed;
  const bg = theme === 'dark' ? spec.d : spec.l;
  const r = Math.round(size * 0.24);
  return (
    <div style={{
      width: size, height: size, borderRadius: r,
      background: bg,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      color: spec.glyphColor, fontSize: Math.round(size * 0.5),
      fontWeight: 600, letterSpacing: -0.5,
      fontFamily: window.SF,
      boxShadow: theme === 'dark'
        ? 'inset 0 0.5px 0 rgba(255,255,255,0.08)'
        : 'inset 0 0.5px 0 rgba(255,255,255,0.2), 0 0.5px 1.5px rgba(0,0,0,0.08)',
      flexShrink: 0,
    }}>
      <span style={{ transform: app === 'safari' ? 'translateY(-1px)' : 'none' }}>{spec.glyph}</span>
    </div>
  );
}

// Keycap — renders modifier glyphs in a native-feeling pill
function Keycap({ children, t }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      minWidth: 20, height: 20, padding: '0 5px',
      background: t.controlBgRest,
      border: `0.5px solid ${t.controlBorder}`,
      borderRadius: 4,
      color: t.textPrimary,
      fontFamily: window.SF,
      fontSize: 12,
      fontWeight: 500,
      lineHeight: 1,
      boxShadow: t.controlShadow,
    }}>{children}</span>
  );
}

// Modifier string: renders raw chars tight (native menu-style)
function ShortcutGlyph({ keys, t }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 1,
      fontFamily: window.SF,
      fontSize: 13,
      color: t.textSecondary,
      letterSpacing: 0.5,
      fontWeight: 500,
    }}>
      {keys}
    </span>
  );
}

// Hyper badge — small violet pill
function HyperBadge({ t }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center',
      padding: '1px 6px',
      background: t.violetBgSoft,
      color: t.violet,
      borderRadius: 4,
      fontSize: 10.5,
      fontWeight: 600,
      letterSpacing: 0.3,
      textTransform: 'uppercase',
      fontFamily: window.SF,
    }}>Hyper</span>
  );
}

// Status dot (running indicator)
function StatusDot({ color, size = 6 }) {
  return <div style={{
    width: size, height: size, borderRadius: '50%',
    background: color,
    boxShadow: `0 0 0 2px ${color}22`,
    flexShrink: 0,
  }} />;
}

// Native-looking toggle switch
function Switch({ on = true, t, size = 'md', onChange }) {
  const w = size === 'sm' ? 28 : 36;
  const h = size === 'sm' ? 16 : 22;
  const knob = h - 4;
  return (
    <div onClick={() => onChange && onChange(!on)} style={{
      width: w, height: h,
      borderRadius: h / 2,
      background: on ? t.accent : (t === window.darkTheme ? '#48484A' : '#D4D4D4'),
      position: 'relative', cursor: 'pointer',
      transition: 'background .18s',
      flexShrink: 0,
      boxShadow: on ? `inset 0 0 0 0.5px ${t.accent}` : 'inset 0 0 0 0.5px rgba(0,0,0,0.05)',
    }}>
      <div style={{
        position: 'absolute', top: 2, left: on ? w - knob - 2 : 2,
        width: knob, height: knob, borderRadius: '50%',
        background: '#FFFFFF',
        boxShadow: '0 1px 2px rgba(0,0,0,0.25), 0 0 0 0.5px rgba(0,0,0,0.06)',
        transition: 'left .18s',
      }} />
    </div>
  );
}

// Native checkbox
function Checkbox({ on = true, t }) {
  return (
    <div style={{
      width: 16, height: 16,
      borderRadius: 4,
      background: on ? t.accent : t.controlBgRest,
      border: on ? `0.5px solid ${t.accent}` : `0.5px solid ${t.controlBorder}`,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      boxShadow: on ? 'none' : t.controlShadow,
      flexShrink: 0,
    }}>
      {on && (
        <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
          <path d="M2 5l2 2 4-4.5" stroke="#fff" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      )}
    </div>
  );
}

// Native-style button
function Button({ children, t, variant = 'secondary', size = 'sm', style = {}, ...rest }) {
  const base = {
    display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 4,
    fontFamily: window.SF,
    fontSize: size === 'sm' ? 12 : 13,
    fontWeight: 500,
    padding: size === 'sm' ? '3px 10px' : '5px 14px',
    borderRadius: 6,
    cursor: 'pointer', userSelect: 'none',
    border: 'none',
    whiteSpace: 'nowrap',
  };
  if (variant === 'primary') {
    return <button {...rest} style={{
      ...base, background: t.accent, color: t.textOnAccent,
      boxShadow: `inset 0 -0.5px 0 rgba(0,0,0,0.15)`,
      ...style,
    }}>{children}</button>;
  }
  if (variant === 'ghost') {
    return <button {...rest} style={{
      ...base, background: 'transparent', color: t.textPrimary,
      ...style,
    }}>{children}</button>;
  }
  // secondary — bordered
  return <button {...rest} style={{
    ...base,
    background: t.controlBg,
    color: t.textPrimary,
    border: `0.5px solid ${t.controlBorder}`,
    boxShadow: t.controlShadow,
    ...style,
  }}>{children}</button>;
}

// Small text field / search
function TextField({ placeholder, value, t, leftIcon, style = {}, inputStyle = {} }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 6,
      padding: '5px 8px',
      background: t.fieldBg,
      border: `0.5px solid ${t.fieldBorder}`,
      borderRadius: 6,
      boxShadow: `inset 0 0.5px 0 rgba(0,0,0,0.03)`,
      fontFamily: window.SF,
      fontSize: 12,
      color: t.textPrimary,
      minHeight: 22,
      ...style,
    }}>
      {leftIcon}
      <span style={{
        color: value ? t.textPrimary : t.textTertiary,
        flex: 1,
        ...inputStyle,
      }}>{value || placeholder}</span>
    </div>
  );
}

// Segmented control (like D/W/M)
function Segmented({ options, value, t, onChange, size = 'sm' }) {
  const h = size === 'sm' ? 24 : 28;
  const isDark = t === window.darkTheme;
  return (
    <div style={{
      display: 'inline-flex',
      background: isDark ? 'rgba(255,255,255,0.06)' : 'rgba(60,60,67,0.12)',
      border: `0.5px solid ${isDark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.08)'}`,
      borderRadius: 7,
      padding: 2,
      gap: 2,
      height: h,
      fontFamily: window.SF,
      fontSize: size === 'sm' ? 11.5 : 12.5,
      fontWeight: 500,
    }}>
      {options.map((opt) => {
        const active = opt === value;
        return (
          <div key={opt} onClick={() => onChange && onChange(opt)} style={{
            padding: '0 11px',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            borderRadius: 5,
            background: active
              ? (isDark ? 'rgba(255,255,255,0.14)' : '#FFFFFF')
              : 'transparent',
            color: active ? t.textPrimary : t.textSecondary,
            fontWeight: active ? 600 : 500,
            boxShadow: active
              ? (isDark
                  ? '0 1px 0 rgba(255,255,255,0.08), 0 1px 3px rgba(0,0,0,0.4)'
                  : '0 1px 0 rgba(255,255,255,0.6), 0 1px 3px rgba(0,0,0,0.12), 0 0 0 0.5px rgba(0,0,0,0.04)')
              : 'none',
            cursor: 'pointer',
            minWidth: 28,
            transition: 'background 120ms ease',
          }}>{opt}</div>
        );
      })}
    </div>
  );
}

// Sidebar icon SVGs — minimal line art matching System Settings vibe
const Icons = {
  keyboard: (c) => (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke={c} strokeWidth="1.2" strokeLinecap="round">
      <rect x="1.5" y="4" width="13" height="8" rx="1.5" />
      <path d="M4 7h.5M6.5 7h.5M9 7h.5M11.5 7h.5M4.5 9.5h7" />
    </svg>
  ),
  gear: (c) => (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke={c} strokeWidth="1.2">
      <circle cx="8" cy="8" r="2.2" />
      <path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4" strokeLinecap="round" />
    </svg>
  ),
  chart: (c) => (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke={c} strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round">
      <path d="M2 13h12M4 10v2M7 6v6M10 8v4M13 3v9" />
    </svg>
  ),
  sparkles: (c) => (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke={c} strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M8 2v3M8 11v3M2 8h3M11 8h3M4 4l2 2M10 10l2 2M4 12l2-2M10 6l2-2" />
    </svg>
  ),
  search: (c) => (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={c} strokeWidth="1.3" strokeLinecap="round">
      <circle cx="5" cy="5" r="3.3" /><path d="M7.5 7.5l2.5 2.5" />
    </svg>
  ),
  plus: (c) => (
    <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke={c} strokeWidth="1.5" strokeLinecap="round"><path d="M5 1v8M1 5h8" /></svg>
  ),
  close: (c) => (
    <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke={c} strokeWidth="1.5" strokeLinecap="round"><path d="M1.5 1.5l7 7M8.5 1.5l-7 7" /></svg>
  ),
  chevronRight: (c) => (
    <svg width="8" height="10" viewBox="0 0 8 10" fill="none" stroke={c} strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"><path d="M2 1.5L6 5l-4 3.5" /></svg>
  ),
  grip: (c) => (
    <svg width="8" height="12" viewBox="0 0 8 12" fill={c}>
      <circle cx="2" cy="2" r="0.9" /><circle cx="6" cy="2" r="0.9" />
      <circle cx="2" cy="6" r="0.9" /><circle cx="6" cy="6" r="0.9" />
      <circle cx="2" cy="10" r="0.9" /><circle cx="6" cy="10" r="0.9" />
    </svg>
  ),
  info: (c) => (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={c} strokeWidth="1.1">
      <circle cx="6" cy="6" r="4.8" />
      <path d="M6 5.5v3M6 4v.1" strokeLinecap="round" />
    </svg>
  ),
  warn: (c) => (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={c} strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M6 1l5 9H1z" /><path d="M6 5v2.5M6 9v.1" />
    </svg>
  ),
  check: (c) => (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={c} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="6" cy="6" r="4.8" />
      <path d="M4 6l1.5 1.5L8.5 4.5" />
    </svg>
  ),
  record: (c) => (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={c} strokeWidth="1.2">
      <circle cx="6" cy="6" r="4.8" /><circle cx="6" cy="6" r="1.8" fill={c} />
    </svg>
  ),
  pause: (c) => (
    <svg width="12" height="12" viewBox="0 0 12 12" fill={c}><rect x="2.5" y="2" width="2.5" height="8" rx="0.6"/><rect x="7" y="2" width="2.5" height="8" rx="0.6"/></svg>
  ),
  flame: (c) => (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={c} strokeWidth="1.2" strokeLinejoin="round">
      <path d="M6 1.5c.5 1.8 2.2 2.7 2.2 4.8A2.7 2.7 0 016 9a2.5 2.5 0 01-2-4C4.6 4.2 5.5 3.6 6 1.5z"/>
    </svg>
  ),
  refresh: (c) => (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={c} strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round">
      <path d="M10 3v2.5H7.5M2 9V6.5h2.5"/><path d="M9 5.5A3.5 3.5 0 003 5M3 6.5A3.5 3.5 0 009 7"/>
    </svg>
  ),
  clock: (c) => (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={c} strokeWidth="1.2" strokeLinecap="round"><circle cx="6" cy="6" r="4.8"/><path d="M6 3.5V6l1.8 1"/></svg>
  ),
};

Object.assign(window, {
  TrafficLights, AppIcon, Keycap, ShortcutGlyph, HyperBadge, StatusDot,
  Switch, Checkbox, Button, TextField, Segmented, Icons,
});
