// Menu bar popover — redesigned.
// Adds: quick search, today mini-bar, pause-all toggle, recently used.
// Retains: shortcut list w/ glyphs. Rounded item rows (NSMenu-style).

function MenubarPopover({ theme = 'light' }) {
  const t = theme === 'dark' ? window.darkTheme : window.lightTheme;
  const isDark = theme === 'dark';
  const shortcuts = [
    { app: 'zed', name: 'Zed', keys: '⌃⌥⇧⌘Z', hyper: true, running: true, count: 10 },
    { app: 'terminal', name: 'Terminal', keys: '⌘⌥T', running: true, count: 32 },
    { app: 'safari', name: 'Safari', keys: '⌘⌥S', running: true, count: 70 },
    { app: 'notes', name: 'Notes', keys: '⌘⌥N', running: true, count: 0 },
  ];
  return (
    <window.PopoverChrome t={t} width={300} height={488}>
      {/* header */}
      <div style={{
        padding: '10px 10px 8px',
        display: 'flex', alignItems: 'center', gap: 8,
      }}>
        <div style={{
          width: 24, height: 24, borderRadius: 6,
          background: `linear-gradient(135deg, ${t.accent} 0%, ${t.violet} 100%)`,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: '#fff',
          boxShadow: '0 1px 2px rgba(0,0,0,0.15), inset 0 1px 0 rgba(255,255,255,0.2)',
        }}><window.Logo_WinkCrescent size={18} color="#fff" /></div>
        <div style={{ flex: 1, fontSize: 13, fontWeight: 600, color: t.textPrimary }}>Wink</div>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 4,
          padding: '2px 6px', borderRadius: 4,
          background: t.greenSoft,
          fontSize: 10.5, color: t.green, fontWeight: 600,
        }}>
          <window.StatusDot color={t.green} size={5} />
          <span>Ready</span>
        </div>
      </div>

      {/* search */}
      <div style={{ padding: '0 10px 8px' }}>
        <window.TextField
          t={t}
          placeholder="Search shortcuts…"
          leftIcon={window.Icons.search(t.textTertiary)}
        />
      </div>

      {/* today mini bar */}
      <div style={{ padding: '0 14px 10px' }}>
        <div style={{
          display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 6,
        }}>
          <window.SectionLabel t={t}>Today</window.SectionLabel>
          <div style={{ fontSize: 10.5, color: t.textTertiary, fontVariantNumeric: 'tabular-nums' }}>
            <span style={{ color: t.textSecondary, fontWeight: 600 }}>23</span> activations
          </div>
        </div>
        <div style={{
          display: 'flex', gap: 2, height: 22, alignItems: 'flex-end',
        }}>
          {[3, 1, 0, 4, 7, 2, 1, 3, 5, 8, 4, 2].map((v, i) => (
            <div key={i} style={{
              flex: 1,
              height: `${Math.max(10, v * 10)}%`,
              background: v === 8 ? t.accent : t.accentBgSoft,
              borderRadius: 1.5,
            }} />
          ))}
        </div>
        <div style={{
          display: 'flex', justifyContent: 'space-between',
          fontSize: 9.5, color: t.textTertiary, marginTop: 3,
          fontVariantNumeric: 'tabular-nums',
        }}>
          <span>12a</span><span>6a</span><span>12p</span><span>6p</span><span>now</span>
        </div>
      </div>

      <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />

      {/* shortcut list */}
      <div style={{ padding: '8px 8px 4px' }}>
        <div style={{
          display: 'flex', justifyContent: 'space-between', alignItems: 'center',
          padding: '0 6px 6px',
        }}>
          <window.SectionLabel t={t}>Shortcuts</window.SectionLabel>
          <div style={{
            fontSize: 10.5, color: t.accent, fontWeight: 500, cursor: 'pointer',
          }}>Manage</div>
        </div>
        {shortcuts.map((s, i) => (
          <div key={i} style={{
            display: 'flex', alignItems: 'center', gap: 9,
            padding: '6px 8px',
            borderRadius: 6,
            background: i === 2 ? (isDark ? 'rgba(255,255,255,0.04)' : 'rgba(0,0,0,0.03)') : 'transparent',
          }}>
            <window.AppIcon app={s.app} size={22} theme={theme} />
            <div style={{ flex: 1, minWidth: 0, display: 'flex', alignItems: 'center', gap: 5 }}>
              <span style={{ fontSize: 13, color: t.textPrimary, fontWeight: 400 }}>{s.name}</span>
              {s.running && <window.StatusDot color={t.green} size={5} />}
            </div>
            {s.hyper && <window.HyperBadge t={t} />}
            <window.ShortcutGlyph t={t} keys={s.keys} />
          </div>
        ))}
      </div>

      <div style={{ flex: 1 }} />

      <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />

      {/* pause toggle */}
      <div style={{ padding: '6px 8px' }}>
        <div style={{
          display: 'flex', alignItems: 'center',
          padding: '6px 8px',
          borderRadius: 6,
          gap: 9,
        }}>
          <div style={{ color: t.textSecondary }}>{window.Icons.pause(t.textSecondary)}</div>
          <div style={{ flex: 1, fontSize: 13, color: t.textPrimary }}>Pause all shortcuts</div>
          <window.Switch on={false} t={t} size="sm" />
        </div>
      </div>

      <div style={{ borderTop: `0.5px solid ${t.hairline}` }} />

      {/* footer — settings / quit */}
      <div style={{ padding: '6px 8px 8px', display: 'flex', flexDirection: 'column', gap: 1 }}>
        {[
          { label: 'Settings…', keys: '⌘,' },
          { label: 'Check for Updates…' },
          { label: 'Quit Wink', keys: '⌘Q' },
        ].map((r, i) => (
          <div key={i} style={{
            display: 'flex', alignItems: 'center',
            padding: '5px 8px',
            borderRadius: 5,
            fontSize: 13, color: t.textPrimary,
          }}>
            <span style={{ flex: 1 }}>{r.label}</span>
            {r.keys && <window.ShortcutGlyph t={t} keys={r.keys} />}
          </div>
        ))}
      </div>
    </window.PopoverChrome>
  );
}

Object.assign(window, { MenubarPopover });
