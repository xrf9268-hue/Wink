// Menubar popover v2 — tighter layout, better logo treatment,
// fixed pause toggle position (right up against the list, not floating).

function MenubarPopover({ theme = 'light', paused = false }) {
  const t = theme === 'dark' ? window.darkTheme : window.lightTheme;
  const isDark = theme === 'dark';
  const shortcuts = [
    { app: 'zed', name: 'Zed', keys: '⌃⌥⇧⌘Z', hyper: true, running: true },
    { app: 'terminal', name: 'Terminal', keys: '⌘⌥T', running: true },
    { app: 'safari', name: 'Safari', keys: '⌘⌥S', running: true, recent: true },
    { app: 'notes', name: 'Notes', keys: '⌘⌥N', running: false },
  ];

  return (
    <window.PopoverChrome t={t} width={308} height={498}>
      {/* header — real app icon, status pill */}
      <div style={{
        padding: '12px 12px 10px',
        display: 'flex', alignItems: 'center', gap: 9,
      }}>
        <window.WinkAppIcon size={24} radius={6} theme={theme} />
        <div style={{
          flex: 1,
          display: 'flex', alignItems: 'center', gap: 6,
        }}>
          <window.Wordmark size={14} color={t.textPrimary} />
          <span style={{ fontSize: 11, color: t.textTertiary, fontWeight: 500 }}>v0.3</span>
        </div>
        {paused ? (
          <div style={{
            display: 'flex', alignItems: 'center', gap: 4,
            padding: '2px 7px', borderRadius: 10,
            background: t.amberBgSoft,
            fontSize: 11, color: t.amber, fontWeight: 600,
          }}>
            <window.StatusDot color={t.amber} size={5} />
            <span>Paused</span>
          </div>
        ) : (
          <div style={{
            display: 'flex', alignItems: 'center', gap: 4,
            padding: '2px 7px', borderRadius: 10,
            background: t.greenSoft,
            fontSize: 11, color: t.green, fontWeight: 600,
          }}>
            <window.StatusDot color={t.green} size={5} />
            <span>Ready</span>
          </div>
        )}
      </div>

      {/* search */}
      <div style={{ padding: '0 12px 10px' }}>
        <window.TextField
          t={t}
          placeholder="Search shortcuts…"
          leftIcon={window.Icons.search(t.textTertiary)}
          style={{ padding: '6px 8px' }}
        />
      </div>

      {/* today mini bar */}
      <div style={{ padding: '0 14px 10px' }}>
        <div style={{
          display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 6,
        }}>
          <window.SectionLabel t={t}>Today</window.SectionLabel>
          <div style={{ fontSize: 11, color: t.textTertiary, fontVariantNumeric: 'tabular-nums' }}>
            <span style={{ color: t.textSecondary, fontWeight: 600 }}>23</span> activations
          </div>
        </div>
        <TodayBar t={t} />
        <div style={{
          display: 'flex', justifyContent: 'space-between',
          fontSize: 10, color: t.textTertiary, marginTop: 4,
          fontVariantNumeric: 'tabular-nums',
          letterSpacing: 0.2,
        }}>
          <span>12 AM</span><span>6 AM</span><span>12 PM</span><span>6 PM</span><span>Now</span>
        </div>
      </div>

      <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />

      {/* shortcut list */}
      <div style={{ padding: '8px 8px 4px', flex: 1, minHeight: 0, overflow: 'hidden' }}>
        <div style={{
          display: 'flex', justifyContent: 'space-between', alignItems: 'center',
          padding: '0 6px 6px',
        }}>
          <window.SectionLabel t={t}>Shortcuts</window.SectionLabel>
          <div style={{
            fontSize: 11, color: t.accent, fontWeight: 500, cursor: 'pointer',
          }}>Manage…</div>
        </div>
        {shortcuts.map((s, i) => (
          <div key={i} style={{
            display: 'flex', alignItems: 'center', gap: 9,
            padding: '6px 8px',
            borderRadius: 6,
            background: s.recent ? (isDark ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.035)') : 'transparent',
          }}>
            <window.AppIcon app={s.app} size={22} theme={theme} />
            <div style={{ flex: 1, minWidth: 0, display: 'flex', alignItems: 'center', gap: 5 }}>
              <span style={{ fontSize: 13, color: t.textPrimary }}>{s.name}</span>
              {s.running && <window.StatusDot color={t.green} size={5} />}
            </div>
            {s.hyper && <window.HyperBadge t={t} size="sm" />}
            <window.ShortcutGlyph t={t} keys={s.keys} size={12} />
          </div>
        ))}
      </div>

      <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />

      {/* pause + footer - all together, no floating section */}
      <div style={{ padding: '4px 6px 6px' }}>
        <MenuRow t={t} icon={paused ? window.Icons.play : window.Icons.pause}
          iconColor={paused ? t.amber : t.textSecondary}>
          <span style={{ flex: 1 }}>{paused ? 'Resume shortcuts' : 'Pause all shortcuts'}</span>
          <window.Switch on={paused} t={t} size="sm" />
        </MenuRow>
        <div style={{ borderTop: `0.5px solid ${t.hairline}`, margin: '4px 2px' }} />
        <MenuRow t={t} icon={window.Icons.gear} iconColor={t.textSecondary}>
          <span style={{ flex: 1 }}>Settings…</span>
          <window.ShortcutGlyph t={t} keys="⌘," size={12} />
        </MenuRow>
        <MenuRow t={t} icon={window.Icons.close} iconColor={t.textSecondary}>
          <span style={{ flex: 1 }}>Quit Wink</span>
          <window.ShortcutGlyph t={t} keys="⌘Q" size={12} />
        </MenuRow>
      </div>
    </window.PopoverChrome>
  );
}

function MenuRow({ t, icon, iconColor, children }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 9,
      padding: '5px 8px',
      borderRadius: 5,
      fontSize: 13, color: t.textPrimary,
      cursor: 'default',
    }}>
      {icon && (
        <div style={{
          width: 14, display: 'flex', justifyContent: 'center', alignItems: 'center',
          color: iconColor,
        }}>{icon(iconColor)}</div>
      )}
      {children}
    </div>
  );
}

// Mini bar — more visually structured than v1's simple bars.
// Current hour (last bar) highlighted; others fade to accent-soft.
function TodayBar({ t }) {
  const data = [0, 0, 1, 0, 0, 2, 1, 3, 4, 2, 1, 3, 5, 4, 2, 1, 3, 2, 1, 0, 0, 0, 0, 0];
  const now = 17; // 5pm-ish, current hour
  const max = Math.max(...data);
  return (
    <div style={{
      display: 'flex', gap: 1.5, height: 26, alignItems: 'flex-end',
    }}>
      {data.map((v, i) => {
        const h = max === 0 ? 0 : (v / max);
        const isNow = i === now;
        const isPast = i < now;
        return (
          <div key={i} style={{
            flex: 1,
            height: `${Math.max(6, h * 100)}%`,
            background: isNow
              ? t.accent
              : (isPast ? t.accentBgSoft : (t === window.darkTheme ? 'rgba(255,255,255,0.04)' : 'rgba(0,0,0,0.04)')),
            borderRadius: 1.5,
            transition: 'background .18s',
          }} />
        );
      })}
    </div>
  );
}

Object.assign(window, { MenubarPopover });
