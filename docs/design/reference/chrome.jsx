// macOS window chrome + menubar popover chrome

// Inject scrollbar styles once — macOS-style overlay scrollbars
if (typeof document !== 'undefined' && !document.getElementById('wink-sb')) {
  const s = document.createElement('style');
  s.id = 'wink-sb';
  s.textContent = `
    .wink-scroll { scrollbar-width: thin; scrollbar-color: rgba(120,120,120,0.35) transparent; }
    .wink-scroll::-webkit-scrollbar { width: 8px; height: 8px; }
    .wink-scroll::-webkit-scrollbar-track { background: transparent; }
    .wink-scroll::-webkit-scrollbar-thumb { background: rgba(120,120,120,0.25); border-radius: 4px; border: 2px solid transparent; background-clip: content-box; }
    .wink-scroll::-webkit-scrollbar-thumb:hover { background: rgba(120,120,120,0.5); background-clip: content-box; border: 2px solid transparent; }
    .wink-scroll.dark::-webkit-scrollbar-thumb { background: rgba(235,235,245,0.22); background-clip: content-box; }
    .wink-scroll.dark::-webkit-scrollbar-thumb:hover { background: rgba(235,235,245,0.38); background-clip: content-box; }
  `;
  document.head.appendChild(s);
}

function WinChrome({ t, title = 'Wink', children, width = 760, height = 560 }) {
  return (
    <div style={{
      width, height,
      background: t.windowBg,
      borderRadius: 10,
      overflow: 'hidden',
      fontFamily: window.SF,
      boxShadow: t === window.darkTheme
        ? '0 0 0 0.5px rgba(255,255,255,0.08), 0 20px 40px rgba(0,0,0,0.5)'
        : '0 0 0 0.5px rgba(0,0,0,0.12), 0 20px 40px rgba(0,0,0,0.15)',
      display: 'flex', flexDirection: 'column',
    }}>
      <div style={{
        height: 36,
        background: t.chromeBg,
        borderBottom: `0.5px solid ${t.chromeBorder}`,
        display: 'flex', alignItems: 'center',
        flexShrink: 0,
        position: 'relative',
      }}>
        <window.TrafficLights />
        <div style={{
          position: 'absolute', inset: 0,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: t.textPrimary, fontSize: 13, fontWeight: 500,
          pointerEvents: 'none',
        }}>{title}</div>
      </div>
      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>{children}</div>
    </div>
  );
}

// Menu-bar popover — tapered triangle notch + vibrancy panel
function PopoverChrome({ t, children, width = 300, height = 460 }) {
  const isDark = t === window.darkTheme;
  return (
    <div style={{
      width, height,
      position: 'relative',
      fontFamily: window.SF,
      paddingTop: 8,
    }}>
      {/* notch */}
      <div style={{
        position: 'absolute', top: 0, left: '50%', transform: 'translateX(-50%)',
        width: 16, height: 8,
        background: 'transparent',
      }}>
        <svg width="16" height="8" viewBox="0 0 16 8"><path d="M0 8 L8 0 L16 8 Z"
          fill={isDark ? '#2D2D30' : '#FFFFFF'}
          stroke={isDark ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.1)'}
          strokeWidth="0.5" /></svg>
      </div>
      <div style={{
        height: height - 8,
        background: isDark ? 'linear-gradient(180deg,#2D2D30 0%,#252527 100%)' : 'linear-gradient(180deg,#FFFFFF 0%,#FAFAFA 100%)',
        border: `0.5px solid ${isDark ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.1)'}`,
        borderRadius: 10,
        boxShadow: isDark
          ? '0 12px 40px rgba(0,0,0,0.6), 0 0 0 0.5px rgba(0,0,0,0.3)'
          : '0 12px 40px rgba(0,0,0,0.18), 0 0 0 0.5px rgba(0,0,0,0.06)',
        overflow: 'hidden',
        display: 'flex', flexDirection: 'column',
      }}>
        {children}
      </div>
    </div>
  );
}

// Sidebar — NSSplitView-style, matches System Settings on macOS 14+
function Sidebar({ t, active, onPick }) {
  const items = [
    { id: 'shortcuts', label: 'Shortcuts', icon: window.Icons.keyboard, badge: '4' },
    { id: 'insights',  label: 'Insights',  icon: window.Icons.chart },
    { id: 'general',   label: 'General',   icon: window.Icons.gear },
  ];
  return (
    <div style={{
      width: 180,
      background: t.sidebarBg,
      borderRight: `0.5px solid ${t.hairline}`,
      padding: '10px 10px',
      display: 'flex', flexDirection: 'column', gap: 2,
    }}>
      {items.map((it) => {
        const isActive = active === it.id;
        return (
          <div key={it.id} onClick={() => onPick && onPick(it.id)} style={{
            display: 'flex', alignItems: 'center', gap: 8,
            padding: '5px 8px',
            borderRadius: 6,
            background: isActive ? t.sidebarItemActive : 'transparent',
            cursor: 'pointer',
            fontSize: 13,
            color: t.textPrimary,
            fontWeight: 400,
          }}>
            <div style={{
              width: 20, height: 20, borderRadius: 4,
              background: isActive ? t.accent : (t === window.darkTheme ? '#5A5A5C' : '#9E9E9E'),
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              flexShrink: 0,
            }}>
              {it.icon('#FFFFFF')}
            </div>
            <span style={{ flex: 1 }}>{it.label}</span>
            {it.badge && (
              <span style={{
                fontSize: 11,
                color: t.textTertiary,
                fontVariantNumeric: 'tabular-nums',
              }}>{it.badge}</span>
            )}
          </div>
        );
      })}
    </div>
  );
}

// Section label (SF Pro caps small) — used by menubar + panel headers
function SectionLabel({ children, t, style = {} }) {
  return (
    <div style={{
      fontSize: 10.5,
      fontWeight: 600,
      color: t.textTertiary,
      letterSpacing: 0.6,
      textTransform: 'uppercase',
      fontFamily: window.SF,
      ...style,
    }}>{children}</div>
  );
}

// Inset card — used on main content
function Card({ t, children, style = {}, title, accessory }) {
  return (
    <div style={{
      background: t.cardBg,
      border: `0.5px solid ${t.cardBorder}`,
      borderRadius: 10,
      boxShadow: t.cardShadow,
      overflow: 'hidden',
      ...style,
    }}>
      {title && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8,
          padding: '10px 14px 8px',
          borderBottom: `0.5px solid ${t.hairline}`,
        }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: t.textPrimary, flex: 1 }}>{title}</div>
          {accessory}
        </div>
      )}
      {children}
    </div>
  );
}

// Banner (info / success / warn / error)
function Banner({ t, kind = 'info', title, body, trailing }) {
  const palette = {
    success: { bg: t.greenSoft, fg: t.green, icon: window.Icons.check },
    info:    { bg: t.accentBgSoft, fg: t.accent, icon: window.Icons.info },
    warn:    { bg: t.amberBgSoft, fg: t.amber, icon: window.Icons.warn },
    error:   { bg: t.redBgSoft,   fg: t.red,   icon: window.Icons.warn },
  }[kind];
  return (
    <div style={{
      display: 'flex', alignItems: 'flex-start', gap: 10,
      padding: '10px 14px',
      background: palette.bg,
      border: `0.5px solid ${palette.fg}33`,
      borderRadius: 10,
    }}>
      <div style={{ marginTop: 1, color: palette.fg }}>{palette.icon(palette.fg)}</div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 12, fontWeight: 600, color: palette.fg, marginBottom: 2 }}>{title}</div>
        {body && <div style={{ fontSize: 11.5, color: t.textSecondary, lineHeight: 1.45 }}>{body}</div>}
      </div>
      {trailing}
    </div>
  );
}

Object.assign(window, { WinChrome, PopoverChrome, Sidebar, SectionLabel, Card, Banner });
