// Insights tab — expanded analytics: summary, sparkline, hourly heatmap,
// streak, and per-app drilldown list with sparklines.

function InsightsTab({ theme = 'light' }) {
  const t = theme === 'dark' ? window.darkTheme : window.lightTheme;

  const apps = [
    { app: 'safari',   name: 'Safari',   count: 70, pct: 0.625, trend: [4,6,8,7,12,14,11,8,10,13,15,12,11,9], change: +18 },
    { app: 'terminal', name: 'Terminal', count: 32, pct: 0.286, trend: [2,4,3,5,6,4,7,3,5,4,6,5,4,3], change: +6 },
    { app: 'zed',      name: 'Zed',      count: 10, pct: 0.089, trend: [1,0,2,1,3,1,2,0,1,2,0,1,1,2], change: -3 },
    { app: 'notes',    name: 'Notes',    count: 0,  pct: 0,     trend: [0,0,0,0,0,0,0,0,0,0,0,0,0,0], change: 0 },
  ];
  const total = apps.reduce((s, a) => s + a.count, 0);
  const topSpark = [6, 9, 14, 11, 18, 21, 16, 12, 15, 19, 24, 22, 18, 16, 14, 17, 20, 23, 19, 15, 12, 9, 7, 6];

  // Heatmap — 7 days × 24 hours
  const rng = (seed) => { let s = seed; return () => (s = (s*9301+49297)%233280, s/233280); };
  const r = rng(7);
  const heat = Array.from({ length: 7 }, (_, d) => Array.from({ length: 24 }, (_, h) => {
    const peak = Math.exp(-Math.pow((h - (d===5||d===6 ? 12 : 10)) / 5, 2));
    return Math.max(0, Math.min(1, peak * (0.6 + r() * 0.6)));
  }));
  const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

  return (
    <div className={`wink-scroll${theme === 'dark' ? ' dark' : ''}`} style={{
      flex: 1, padding: '18px 22px 22px',
      overflow: 'auto',
      display: 'flex', flexDirection: 'column', gap: 16,
    }}>
      {/* header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 20, fontWeight: 600, color: t.textPrimary, letterSpacing: -0.3 }}>Insights</div>
          <div style={{ fontSize: 12, color: t.textSecondary, marginTop: 2 }}>
            How your shortcuts are actually being used.
          </div>
        </div>
        <window.Segmented t={t} options={['D', 'W', 'M', 'Y']} value="W" />
      </div>

      {/* KPI row */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
        <Kpi t={t} label="Activations" value={total} delta="+21%" up spark={topSpark} accent={t.accent} />
        <Kpi t={t} label="Time saved" value="18m" sub="~3s each" icon={window.Icons.clock(t.textSecondary)} />
        <Kpi t={t} label="Streak" value="12d" sub="Longest: 27 days" icon={window.Icons.flame(t.amber)} />
      </div>

      {/* Heatmap */}
      <window.Card t={t} title="Activity by hour"
        accessory={<div style={{ fontSize: 11, color: t.textTertiary }}>Busy around <span style={{ color: t.textSecondary, fontWeight: 500 }}>10 AM – 2 PM</span></div>}
      >
        <div style={{ padding: '12px 14px 14px' }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
            {heat.map((row, di) => (
              <div key={di} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <div style={{ width: 24, fontSize: 10, color: t.textTertiary, fontVariantNumeric: 'tabular-nums' }}>{days[di]}</div>
                <div style={{ flex: 1, display: 'grid', gridTemplateColumns: 'repeat(24, 1fr)', gap: 2 }}>
                  {row.map((v, hi) => (
                    <div key={hi} style={{
                      height: 14,
                      borderRadius: 2,
                      background: v < 0.05
                        ? (theme === 'dark' ? 'rgba(255,255,255,0.04)' : 'rgba(0,0,0,0.04)')
                        : `rgba(${theme==='dark'?'42,143,255':'0,100,224'},${0.10 + v * 0.75})`,
                    }} />
                  ))}
                </div>
              </div>
            ))}
          </div>
          <div style={{ display: 'flex', marginTop: 8, paddingLeft: 32, gap: 2 }}>
            {Array.from({ length: 8 }).map((_, i) => (
              <div key={i} style={{
                flex: 1,
                fontSize: 9.5, color: t.textTertiary, textAlign: 'left',
                fontVariantNumeric: 'tabular-nums',
              }}>{`${i*3}`.padStart(2,'0')}</div>
            ))}
          </div>
        </div>
      </window.Card>

      {/* Most-used apps */}
      <window.Card t={t} title="Most used"
        accessory={<div style={{ fontSize: 11, color: t.textTertiary }}>{total} activations · 7 days</div>}
      >
        {apps.map((a, i) => (
          <div key={i} style={{
            display: 'flex', alignItems: 'center', gap: 12,
            padding: '10px 14px',
            borderTop: i === 0 ? 'none' : `0.5px solid ${t.hairline}`,
          }}>
            <window.AppIcon app={a.app} size={28} theme={theme} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
                <span style={{ fontSize: 13, color: t.textPrimary, fontWeight: 500 }}>{a.name}</span>
                {a.change !== 0 && (
                  <span style={{
                    fontSize: 10.5, fontWeight: 600,
                    color: a.change > 0 ? t.green : t.red,
                  }}>
                    {a.change > 0 ? '↑' : '↓'} {Math.abs(a.change)}%
                  </span>
                )}
              </div>
              <div style={{
                marginTop: 5,
                height: 5,
                background: theme === 'dark' ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.04)',
                borderRadius: 3, overflow: 'hidden',
              }}>
                <div style={{
                  height: '100%',
                  width: `${a.pct * 100}%`,
                  background: a.count === 0
                    ? (theme === 'dark' ? 'rgba(255,255,255,0.1)' : 'rgba(0,0,0,0.1)')
                    : t.accent,
                  borderRadius: 3,
                }} />
              </div>
            </div>
            <Sparkline points={a.trend} w={80} h={24} stroke={a.count ? t.accent : t.textTertiary} fill={a.count ? t.accentBgSoft : 'transparent'} />
            <div style={{
              fontSize: 13, fontWeight: 600, color: t.textPrimary,
              fontVariantNumeric: 'tabular-nums', minWidth: 28, textAlign: 'right',
            }}>{a.count}</div>
          </div>
        ))}
      </window.Card>

      {/* Tip */}
      <div style={{
        display: 'flex', alignItems: 'flex-start', gap: 10,
        padding: '10px 14px',
        background: t.accentBgSoft,
        border: `0.5px solid ${t.accentBorderSoft}`,
        borderRadius: 10,
      }}>
        <div style={{ marginTop: 1, color: t.accent }}>{window.Icons.sparkles(t.accent)}</div>
        <div style={{ flex: 1, fontSize: 12, color: t.textSecondary, lineHeight: 1.5 }}>
          <span style={{ color: t.textPrimary, fontWeight: 500 }}>Notes hasn't been used this week.</span>{' '}
          Consider turning it off, or rebinding it to an app you reach for more often.
        </div>
        <window.Button t={t}>Review</window.Button>
      </div>
    </div>
  );
}

function Kpi({ t, label, value, sub, delta, up, spark, icon, accent }) {
  return (
    <window.Card t={t} style={{ display: 'flex', flexDirection: 'column' }}>
      <div style={{ padding: '12px 14px', display: 'flex', flexDirection: 'column', flex: 1 }}>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 6,
          fontSize: 11, color: t.textSecondary, fontWeight: 500,
        }}>
          {icon}
          <span>{label}</span>
        </div>
        <div style={{
          marginTop: 4,
          display: 'flex', alignItems: 'baseline', gap: 6,
        }}>
          <div style={{ fontSize: 26, fontWeight: 600, color: t.textPrimary, letterSpacing: -0.6, lineHeight: 1 }}>{value}</div>
          {delta && (
            <div style={{
              fontSize: 11, fontWeight: 600,
              color: up ? t.green : t.red,
            }}>{delta}</div>
          )}
        </div>
        {sub && <div style={{ fontSize: 11, color: t.textTertiary, marginTop: 4 }}>{sub}</div>}
        <div style={{ flex: 1, minHeight: 8 }} />
        <div style={{ height: 28, marginTop: 4 }}>
          {spark && <Sparkline points={spark} w={220} h={28} stroke={accent} fill={t.accentBgSoft} full />}
        </div>
      </div>
    </window.Card>
  );
}

function Sparkline({ points, w = 80, h = 24, stroke, fill, full }) {
  const max = Math.max(1, ...points);
  const step = w / (points.length - 1 || 1);
  const pts = points.map((v, i) => [i * step, h - (v / max) * (h - 2) - 1]);
  const path = pts.map((p, i) => (i === 0 ? 'M' : 'L') + p[0].toFixed(1) + ',' + p[1].toFixed(1)).join(' ');
  const area = `${path} L${w},${h} L0,${h} Z`;
  return (
    <svg width={full ? '100%' : w} height={h} viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none">
      {fill && fill !== 'transparent' && <path d={area} fill={fill} />}
      <path d={path} fill="none" stroke={stroke} strokeWidth="1.4" strokeLinejoin="round" strokeLinecap="round" />
    </svg>
  );
}

Object.assign(window, { InsightsTab });
